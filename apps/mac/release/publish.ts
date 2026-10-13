#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import { createHash, createHmac } from 'node:crypto';
import { appendFileSync, existsSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { parseArgs } from 'node:util';
import {
  type AppcastReleaseItem,
  assertNewRelease,
  extractChangelogSection,
  updateAppcast,
} from './appcast.ts';

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
      tag: { type: 'string' },
      'notes-file': { type: 'string' },
      'dry-run': { type: 'boolean', default: false },
      prefix: { type: 'string', default: '' },
    },
    strict: true,
  });

  return {
    check: values.check ?? false,
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
): Promise<{ status: number; text: () => Promise<string> }> => {
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
    'x-amz-content-sha256': payloadHash,
    'x-amz-date': amzDate,
  };
  if (contentType) {
    headers['content-type'] = contentType;
  }

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

const fetchR2Object = async (key: string): Promise<string | null> => {
  const res = await r2Request('GET', key);
  if (res.status === 200) {
    return await res.text();
  }
  if (res.status === 404) {
    return null;
  }
  const body = await res.text();
  throw new Error(`R2 GET ${key} failed (status ${res.status}):\n${body}`);
};

const putR2Object = async (
  key: string,
  body: string | Buffer,
  contentType: string,
): Promise<void> => {
  const res = await r2Request('PUT', key, body, contentType);
  if (res.status !== 200 && res.status !== 204) {
    const text = await res.text();
    throw new Error(`R2 PUT ${key} failed (status ${res.status}): ${text}`);
  }
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

/** Checks a release before its build: `tag` is the tag being released, which must name this version. */
export const runPreflightCheck = async (
  tag: string,
  notesFile?: string,
): Promise<{ version: string }> => {
  const version = getMarketingVersion();
  const build = getBuildNumber();
  console.log(`Checking release preflight for version ${version} (build ${build})...`);

  if (!existsSync(CHANGELOG_PATH)) {
    throw new Error(`CHANGELOG.md not found at ${CHANGELOG_PATH}`);
  }
  const releaseNotes = extractChangelogSection(readFileSync(CHANGELOG_PATH, 'utf8'), version);
  console.log(`✓ CHANGELOG.md contains section for ## ${version}`);
  if (notesFile !== undefined) writeFileSync(notesFile, `${releaseNotes}\n`);

  if (tag !== releaseTag(version)) {
    throw new Error(
      `Tag "${tag}" does not name MARKETING_VERSION ${version}: release it as "${releaseTag(version)}".`,
    );
  }
  console.log(`✓ Tag "${tag}" names version ${version}`);

  assertNewRelease(await fetchLiveAppcast(), { shortVersionString: version, version: build });
  console.log(`✓ Build ${build} is above every build in the live appcast`);

  if (process.env.GITHUB_OUTPUT) {
    appendFileSync(process.env.GITHUB_OUTPUT, `version=${version}\n`);
  }

  console.log(`Preflight check passed: ready to cut release ${version}`);
  return { version };
};

const main = async () => {
  const options = parseCliArgs();

  if (options.check) {
    if (options.tag === undefined) throw new Error('--check needs --tag <the tag being released>');
    await runPreflightCheck(options.tag, options.notesFile);
    return;
  }

  console.log('=== DirBuff Release Publisher ===');
  const marketingVersion = getMarketingVersion();
  const minimumSystemVersion = getMinimumSystemVersion();
  console.log(`Target version: ${marketingVersion} (min macOS: ${minimumSystemVersion})`);

  // The build number release.sh gave CFBundleVersion.
  const buildNumber = getBuildNumber();
  console.log(`Release build number: ${buildNumber}`);

  const changelogContent = readFileSync(CHANGELOG_PATH, 'utf8');
  const releaseNotes = extractChangelogSection(changelogContent, marketingVersion);
  console.log(`Extracted release notes for ${marketingVersion} (${releaseNotes.length} chars)`);

  const dmgFilename = dmgFilenameOf(marketingVersion);
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
    title: `Version ${marketingVersion}`,
    pubDate: new Date().toUTCString(),
    version: buildNumber,
    shortVersionString: marketingVersion,
    minimumSystemVersion,
    releaseNotes,
    enclosureUrl: dmgUrlOf(marketingVersion),
    enclosureLength: dmgStat.size,
    enclosureType: 'application/x-apple-diskimage',
    edSignature,
  };

  const appcastKey = `${options.prefix}appcast.xml`;
  let existingAppcastXml: string | null = null;

  if (options.dryRun && (!process.env.R2_ACCESS_KEY_ID || !process.env.R2_SECRET_ACCESS_KEY)) {
    console.log('[dry-run] R2 credentials not set; generating appcast from scratch.');
  } else {
    console.log(`Fetching live appcast from R2 (${appcastKey})...`);
    existingAppcastXml = await fetchR2Object(appcastKey);
    if (existingAppcastXml === null) {
      console.log('No existing appcast found in R2; creating new feed.');
    } else {
      console.log('Fetched existing appcast. Validating version & build uniqueness...');
    }
  }

  const newAppcastXml = updateAppcast(existingAppcastXml, releaseItem);

  // The site's /download redirects to `url`.
  const latestJson = `${JSON.stringify({ version: marketingVersion, url: dmgUrlOf(marketingVersion) }, null, 2)}\n`;

  const latestKey = `${options.prefix}latest.json`;

  if (options.dryRun) {
    console.log('\n[dry-run] Planned R2 Uploads (in order):');
    console.log(`1. Appcast: ${appcastKey} (${newAppcastXml.length} chars, application/xml)`);
    console.log(`2. Latest: ${latestKey} (${latestJson.trim()})`);
    console.log('\n[dry-run] Preview of new appcast:');
    console.log(newAppcastXml);
    console.log('\n[dry-run] Complete. Nothing was uploaded to R2.');
    return;
  }

  // The DMG is already a published GitHub release asset: the appcast must name only a file that
  // exists, so this runs after the release is created.
  console.log(`\nUploading 1/2: appcast.xml -> ${appcastKey}...`);
  await putR2Object(appcastKey, newAppcastXml, 'application/xml; charset=utf-8');

  console.log(`Uploading 2/2: latest.json -> ${latestKey}...`);
  await putR2Object(latestKey, latestJson, 'application/json; charset=utf-8');

  console.log('\n=== Publication Complete ===');
  console.log(
    `Version ${marketingVersion} (build ${buildNumber}) published: the feed and latest.json are on R2.`,
  );
};

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch(error => {
    console.error('\nPublish failed:');
    console.error(error instanceof Error ? error.message : error);
    process.exit(1);
  });
}
