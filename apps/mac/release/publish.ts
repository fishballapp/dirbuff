#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import { createHash, createHmac } from 'node:crypto';
import { appendFileSync, existsSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { parseArgs } from 'node:util';
import {
  type AppcastReleaseItem,
  assertNewRelease,
  devVersionsOf,
  extractChangelogSection,
  updateAppcast,
} from './appcast.ts';
import { devRelease, staleDevTags } from './version.ts';

const SCRIPT_DIR = import.meta.dirname;
const APP_DIR = resolve(SCRIPT_DIR, '..');
const PROJECT_YML_PATH = join(APP_DIR, 'project.yml');
const CHANGELOG_PATH = resolve(SCRIPT_DIR, '../../../CHANGELOG.md');
const OUT_DIR = join(APP_DIR, 'out');

// R2 holds only the feed (`appcast.xml`) and `latest.json`; the DMGs are GitHub release assets.
const ACCOUNT_ID = 'ef1db00eff7bafcb12e7acb5754d1377';
const BUCKET = 'dirbuff-releases';
const APPCAST_URL = 'https://dirbuff.fishball.app/appcast.xml';
const REPOSITORY = 'fishballapp/dirbuff';

const releaseTag = (version: string): string => `v${version}`;
const dmgFilenameOf = (version: string): string => `DirBuff-${version}.dmg`;
const dmgUrlOf = (version: string): string =>
  `https://github.com/${REPOSITORY}/releases/download/${releaseTag(version)}/${dmgFilenameOf(version)}`;

const parseCliArgs = () => {
  const rawArgs = process.argv.slice(2).filter(arg => arg !== '--');
  const { values } = parseArgs({
    args: rawArgs,
    options: {
      check: { type: 'boolean', default: false },
      dev: { type: 'boolean', default: false },
      tag: { type: 'string' },
      'notes-file': { type: 'string' },
      'dry-run': { type: 'boolean', default: false },
      prefix: { type: 'string', default: '' },
    },
    strict: true,
  });

  return {
    check: values.check ?? false,
    isDev: values.dev ?? false,
    tag: values.tag,
    notesFile: values['notes-file'],
    dryRun: values['dry-run'] ?? false,
    prefix: values.prefix ?? '',
  };
};

const getMarketingVersion = (): string => {
  if (!existsSync(PROJECT_YML_PATH)) {
    throw new Error(`project.yml not found at: ${PROJECT_YML_PATH}`);
  }
  const content = readFileSync(PROJECT_YML_PATH, 'utf8');
  const match = content.match(/MARKETING_VERSION:\s*["']?([^"'\s]+)["']?/);
  if (!match || !match[1]) {
    throw new Error('Unable to extract MARKETING_VERSION from project.yml');
  }
  return match[1].trim();
};

/** The build number: Sparkle offers an update only when it is above the installed one's. */
const getBuildNumber = (): string => {
  const content = readFileSync(PROJECT_YML_PATH, 'utf8');
  const match = content.match(/CURRENT_PROJECT_VERSION:\s*["']?(\d+)["']?/);
  if (!match || !match[1]) {
    throw new Error('Unable to extract CURRENT_PROJECT_VERSION from project.yml');
  }
  return match[1];
};

const getMinimumSystemVersion = (): string => {
  if (!existsSync(PROJECT_YML_PATH)) {
    return '14.0';
  }
  const content = readFileSync(PROJECT_YML_PATH, 'utf8');
  const match = content.match(/MACOSX_DEPLOYMENT_TARGET:\s*["']?([^"'\s]+)["']?/);
  return match && match[1] ? match[1].trim() : '14.0';
};

const sha256 = (data: string | Buffer): string => createHash('sha256').update(data).digest('hex');

const hmac = (key: string | Buffer, data: string): Buffer =>
  createHmac('sha256', key).update(data).digest();

const getSigningKey = (secretKey: string, dateStamp: string): Buffer => {
  const kDate = hmac(`AWS4${secretKey}`, dateStamp);
  const kRegion = hmac(kDate, 'auto');
  const kService = hmac(kRegion, 's3');
  return hmac(kService, 'aws4_request');
};

const r2Request = async (
  method: 'GET' | 'PUT',
  key: string,
  body: string | Buffer | null = null,
  contentType?: string,
  conditions: Record<string, string> = {},
): Promise<Response> => {
  const accessKeyId = process.env.R2_ACCESS_KEY_ID;
  const secretAccessKey = process.env.R2_SECRET_ACCESS_KEY;
  if (!accessKeyId || !secretAccessKey) {
    throw new Error(
      'R2_ACCESS_KEY_ID and R2_SECRET_ACCESS_KEY environment variables are required.',
    );
  }

  const host = `${ACCOUNT_ID}.r2.cloudflarestorage.com`;
  const path = `/${BUCKET}/${key}`;
  const now = new Date();
  const amzDate = now.toISOString().replace(/[:-]|\.\d{3}/g, '');
  const dateStamp = amzDate.slice(0, 8);
  const payloadHash = body ? sha256(body) : sha256('');

  const headers: Record<string, string> = {
    host,
    // The bytes as stored. Fetch asks for gzip by default, and R2 then compresses the feed and
    // answers with a weak ETag (`W/"…"`), which an `If-Match` never matches: every write is a 412.
    'accept-encoding': 'identity',
    'x-amz-content-sha256': payloadHash,
    'x-amz-date': amzDate,
  };
  if (contentType) {
    headers['content-type'] = contentType;
  }
  // Signed with the rest: a conditional header left out of SignedHeaders is ignored or refused.
  Object.assign(headers, conditions);

  const signedHeaders = Object.keys(headers).sort().join(';');
  const canonicalHeaders = Object.keys(headers)
    .sort()
    .map(k => `${k}:${headers[k]}\n`)
    .join('');

  const canonicalRequest = [method, path, '', canonicalHeaders, signedHeaders, payloadHash].join(
    '\n',
  );

  const stringToSign = [
    'AWS4-HMAC-SHA256',
    amzDate,
    `${dateStamp}/auto/s3/aws4_request`,
    sha256(canonicalRequest),
  ].join('\n');

  const signingKey = getSigningKey(secretAccessKey, dateStamp);
  const signature = createHmac('sha256', signingKey).update(stringToSign).digest('hex');
  const auth = `AWS4-HMAC-SHA256 Credential=${accessKeyId}/${dateStamp}/auto/s3/aws4_request, SignedHeaders=${signedHeaders}, Signature=${signature}`;

  return await fetch(`https://${host}${path}`, {
    method,
    headers: {
      ...headers,
      Authorization: auth,
    },
    body: (body === null ? undefined : body) as unknown as BodyInit,
  });
};

/** An object and the ETag a conditional write against it must quote; `null` when it doesn't exist. */
const fetchR2Object = async (key: string): Promise<{ body: string; etag: string } | null> => {
  const res = await r2Request('GET', key);
  if (res.status === 404) return null;
  if (res.status !== 200) {
    throw new Error(`R2 GET ${key} failed (status ${res.status}):\n${await res.text()}`);
  }
  const etag = res.headers.get('etag');
  if (etag === null) throw new Error(`R2 GET ${key} returned no ETag.`);
  return { body: await res.text(), etag };
};

/** Resolves `false` when the precondition failed: someone else wrote the object first. */
const putR2Object = async (
  key: string,
  body: string | Buffer,
  contentType: string,
  conditions: Record<string, string> = {},
): Promise<boolean> => {
  const res = await r2Request('PUT', key, body, contentType, conditions);
  if (res.status === 412) return false;
  if (res.status !== 200 && res.status !== 204) {
    throw new Error(`R2 PUT ${key} failed (status ${res.status}): ${await res.text()}`);
  }
  return true;
};

const FEED_WRITE_ATTEMPTS = 5;

/**
 * Read-modify-write of the feed. A dev run on `main` and a tag run on the same commit can both
 * write it, so the write only lands if the feed is still the one `change` was made from (R2 answers
 * 412 otherwise); then it is read again and `change` re-applied.
 */
export const writeAppcast = async (
  key: string,
  change: (existingXml: string | null) => string,
): Promise<string> => {
  for (let attempt = 1; attempt <= FEED_WRITE_ATTEMPTS; attempt++) {
    const existing = await fetchR2Object(key);
    const xml = change(existing?.body ?? null);
    const conditions: Record<string, string> =
      existing === null ? { 'if-none-match': '*' } : { 'if-match': existing.etag };
    if (await putR2Object(key, xml, 'application/xml; charset=utf-8', conditions)) return xml;
    console.log(`The feed changed under this run (attempt ${attempt}); reading it again...`);
  }
  throw new Error(`The feed kept changing: gave up after ${FEED_WRITE_ATTEMPTS} attempts.`);
};

/** `sign_update -p` prints only the base64 EdDSA signature: 64 bytes, 88 characters. */
const signDmg = (signUpdatePath: string, dmgPath: string, privateKeyBase64: string): string => {
  const signature = execFileSync(signUpdatePath, ['-f', '-', '-p', dmgPath], {
    input: privateKeyBase64,
    encoding: 'utf8',
  }).trim();
  if (!/^[A-Za-z0-9+/]{86}==$/.test(signature)) {
    throw new Error('sign_update did not print an EdDSA signature.');
  }
  return signature;
};

/** The feed installed copies read; `null` before the first release. */
const fetchLiveAppcast = async (): Promise<string | null> => {
  const res = await fetch(APPCAST_URL);
  if (res.status === 404) return null;
  if (!res.ok) throw new Error(`GET ${APPCAST_URL} failed (status ${res.status})`);
  return await res.text();
};

const git = (...args: string[]): string =>
  execFileSync('git', args, { cwd: APP_DIR, encoding: 'utf8' }).trim();

type ResolvedRelease = {
  readonly channel?: 'dev';
  /** The version people see. */
  readonly version: string;
  readonly build: string;
  /** The feed item's notes. */
  readonly notes: string;
  /** The GitHub release's notes. */
  readonly githubNotes: string;
};

/** The release `project.yml` and CHANGELOG.md describe. */
const resolveStableRelease = (): ResolvedRelease => {
  const version = getMarketingVersion();
  if (!existsSync(CHANGELOG_PATH)) {
    throw new Error(`CHANGELOG.md not found at ${CHANGELOG_PATH}`);
  }
  const notes = extractChangelogSection(readFileSync(CHANGELOG_PATH, 'utf8'), version);
  console.log(`✓ CHANGELOG.md contains section for ## ${version}`);
  return { version, build: getBuildNumber(), notes, githubNotes: notes };
};

/** The dev build of the checked-out commit of `main`; its notes are the commit's message. */
const resolveDevRelease = (): ResolvedRelease => {
  const { version, build } = devRelease({
    marketingVersion: getMarketingVersion(),
    build: getBuildNumber(),
    commitCount: Number(git('rev-list', '--count', 'HEAD')),
  });
  const notes = git('log', '-1', '--format=%B');
  const githubNotes = `Dev build of main at ${git('rev-parse', '--short=7', 'HEAD')}. Served to the dev update channel; not for general use.\n\n${notes}`;
  return { channel: 'dev', version, build, notes, githubNotes };
};

/**
 * Checks a release before its build. A stable one is released by `tag`, which must name this
 * version; a dev build has no tag of its own, it is made from the commit.
 */
export const runPreflightCheck = async ({
  isDev,
  tag,
  notesFile,
}: {
  isDev: boolean;
  tag?: string;
  notesFile?: string;
}): Promise<ResolvedRelease> => {
  const release = isDev ? resolveDevRelease() : resolveStableRelease();
  console.log(
    `Checking release preflight for ${isDev ? 'dev build ' : 'version '}${release.version} (build ${release.build})...`,
  );
  if (notesFile !== undefined) writeFileSync(notesFile, `${release.githubNotes}\n`);

  if (!isDev && tag !== releaseTag(release.version)) {
    throw new Error(
      `Tag "${tag}" does not name MARKETING_VERSION ${release.version}: release it as "${releaseTag(release.version)}".`,
    );
  }
  if (!isDev) console.log(`✓ Tag "${tag}" names version ${release.version}`);

  assertNewRelease(await fetchLiveAppcast(), {
    shortVersionString: release.version,
    version: release.build,
    channel: release.channel,
  });
  console.log(
    `✓ Build ${release.build} is above every build it is compared with in the live appcast`,
  );

  if (process.env.GITHUB_OUTPUT) {
    appendFileSync(
      process.env.GITHUB_OUTPUT,
      `version=${release.version}\nbuild=${release.build}\n`,
    );
  }

  console.log(`Preflight check passed: ready to cut release ${release.version}`);
  return release;
};

/** Deletes the GitHub dev releases the feed no longer keeps, with their tags. */
const pruneDevReleases = (keptVersions: readonly string[]): void => {
  const releases: { tagName: string }[] = JSON.parse(
    execFileSync(
      'gh',
      ['release', 'list', '--repo', REPOSITORY, '--limit', '100', '--json', 'tagName'],
      { encoding: 'utf8' },
    ),
  );
  const stale = staleDevTags(
    releases.map(({ tagName }) => tagName),
    keptVersions.map(releaseTag),
  );
  for (const tag of stale) {
    console.log(`Pruning dev release ${tag}...`);
    execFileSync('gh', ['release', 'delete', tag, '--cleanup-tag', '--yes', '--repo', REPOSITORY], {
      stdio: 'inherit',
    });
  }
};

const main = async () => {
  const options = parseCliArgs();

  if (options.check) {
    if (!options.isDev && options.tag === undefined) {
      throw new Error('--check needs --tag <the tag being released>, or --dev');
    }
    await runPreflightCheck({
      isDev: options.isDev,
      tag: options.tag,
      notesFile: options.notesFile,
    });
    return;
  }

  console.log('=== DirBuff Release Publisher ===');
  const release = options.isDev ? resolveDevRelease() : resolveStableRelease();
  const minimumSystemVersion = getMinimumSystemVersion();
  console.log(
    `Target version: ${release.version} (build ${release.build}, min macOS: ${minimumSystemVersion})`,
  );
  console.log(`Release notes: ${release.notes.length} chars`);

  const dmgFilename = dmgFilenameOf(release.version);
  const dmgPath = join(OUT_DIR, dmgFilename);
  const signUpdatePath = join(OUT_DIR, 'sign_update');

  const dmgExists = existsSync(dmgPath);
  if (!dmgExists && !options.dryRun) {
    throw new Error(`DMG artifact not found: ${dmgPath}. Run release.sh first.`);
  }
  const dmgStat = dmgExists ? statSync(dmgPath) : { size: 10485760 };
  console.log(`DMG artifact: ${dmgPath} (${dmgStat.size} bytes${dmgExists ? '' : ' [mock]'})`);

  let edSignature: string;
  const privateKey = process.env.SPARKLE_PRIVATE_KEY;

  if (options.dryRun && (!privateKey || !existsSync(signUpdatePath) || !dmgExists)) {
    console.log('[dry-run] Using placeholder EdDSA signature.');
    edSignature = 'dry-run-placeholder-signature==';
  } else {
    if (!privateKey) {
      throw new Error('SPARKLE_PRIVATE_KEY environment variable is required.');
    }
    if (!existsSync(signUpdatePath)) {
      throw new Error(`Sparkle sign_update binary not found at: ${signUpdatePath}`);
    }
    console.log('Signing DMG with Sparkle EdDSA key via stdin...');
    edSignature = signDmg(signUpdatePath, dmgPath, privateKey);
    console.log('Successfully generated EdDSA signature.');
  }

  const releaseItem: AppcastReleaseItem = {
    channel: release.channel,
    title: `Version ${release.version}`,
    pubDate: new Date().toUTCString(),
    version: release.build,
    shortVersionString: release.version,
    minimumSystemVersion,
    releaseNotes: release.notes,
    enclosureUrl: dmgUrlOf(release.version),
    enclosureLength: dmgStat.size,
    enclosureType: 'application/x-apple-diskimage',
    edSignature,
  };

  const appcastKey = `${options.prefix}appcast.xml`;
  // `latest.json` is what the site's /download redirects to: stable releases only.
  const latestKey = `${options.prefix}latest.json`;
  const latestJson = `${JSON.stringify({ version: release.version, url: dmgUrlOf(release.version) }, null, 2)}\n`;

  if (options.dryRun) {
    const hasCredentials = process.env.R2_ACCESS_KEY_ID && process.env.R2_SECRET_ACCESS_KEY;
    console.log(
      hasCredentials
        ? `Fetching live appcast from R2 (${appcastKey})...`
        : '[dry-run] R2 credentials not set; reading the public feed.',
    );
    const existingXml = hasCredentials
      ? ((await fetchR2Object(appcastKey))?.body ?? null)
      : await fetchLiveAppcast();
    const newAppcastXml = updateAppcast(existingXml, releaseItem);

    console.log('\n[dry-run] Planned writes (in order):');
    console.log(
      `1. Appcast: ${appcastKey} (${newAppcastXml.length} chars, application/xml), only if it is still the feed just read`,
    );
    console.log(
      release.channel === 'dev'
        ? `2. GitHub dev releases older than the feed's newest and not among ${devVersionsOf(newAppcastXml).map(releaseTag).join(', ')} are deleted with their tags (latest.json is not touched)`
        : `2. Latest: ${latestKey} (${latestJson.trim()})`,
    );
    console.log('\n[dry-run] Preview of new appcast:');
    console.log(newAppcastXml);
    console.log('\n[dry-run] Complete. Nothing was uploaded to R2.');
    return;
  }

  // The DMG is already a published GitHub release asset: the appcast must name only a file that
  // exists, so this runs after the release is created.
  console.log(`\nUpdating the feed: ${appcastKey}...`);
  const newAppcastXml = await writeAppcast(appcastKey, existingXml =>
    updateAppcast(existingXml, releaseItem),
  );

  if (release.channel === 'dev') {
    pruneDevReleases(devVersionsOf(newAppcastXml));
  } else {
    console.log(`Uploading latest.json -> ${latestKey}...`);
    await putR2Object(latestKey, latestJson, 'application/json; charset=utf-8');
  }

  console.log('\n=== Publication Complete ===');
  console.log(`Version ${release.version} (build ${release.build}) published to the feed.`);
};

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch(error => {
    console.error('\nPublish failed:');
    console.error(error instanceof Error ? error.message : error);
    process.exit(1);
  });
}
