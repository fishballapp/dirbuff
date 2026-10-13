#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import { appendFileSync, existsSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { parseArgs } from 'node:util';
import { assertNewRelease, extractChangelogSection, formatItemXml } from './appcast.ts';
import {
  dmgFilenameOf,
  dmgUrlOf,
  fetchFeedItems,
  fetchPublishedReleases,
  ITEM_ASSET,
  REPOSITORY,
  releaseTag,
} from './feed.ts';
import { devRelease, staleDevTags } from './version.ts';

// The release job's steps around the build, one flag each:
// - `--check`: before the build, the release's version, build and notes, refused unless the feed
//   would offer it.
// - `--item`: after the build, the release's appcast item, signed, for the GitHub release to carry
//   beside its DMG (feed.ts gathers the items into the feed).
// - `--prune-dev`: after a dev build is published, delete all but the newest dev releases.

const SCRIPT_DIR = import.meta.dirname;
const APP_DIR = resolve(SCRIPT_DIR, '..');
const PROJECT_YML_PATH = join(APP_DIR, 'project.yml');
const CHANGELOG_PATH = resolve(SCRIPT_DIR, '../../../CHANGELOG.md');
const OUT_DIR = join(APP_DIR, 'out');

const parseCliArgs = () => {
  const rawArgs = process.argv.slice(2).filter(arg => arg !== '--');
  const { values } = parseArgs({
    args: rawArgs,
    options: {
      check: { type: 'boolean', default: false },
      item: { type: 'boolean', default: false },
      'prune-dev': { type: 'boolean', default: false },
      dev: { type: 'boolean', default: false },
      tag: { type: 'string' },
      'notes-file': { type: 'string' },
    },
    strict: true,
  });

  return {
    check: values.check ?? false,
    item: values.item ?? false,
    pruneDev: values['prune-dev'] ?? false,
    isDev: values.dev ?? false,
    tag: values.tag,
    notesFile: values['notes-file'],
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

/**
 * The dev build of the checked-out commit of `main`; its notes are the commit's message, less the
 * `ref-hash:` trailer naming the private commit it was exported from.
 */
const resolveDevRelease = (): ResolvedRelease => {
  const { version, build } = devRelease({
    marketingVersion: getMarketingVersion(),
    build: getBuildNumber(),
    commitCount: Number(git('rev-list', '--count', 'HEAD')),
  });
  const notes = git('log', '-1', '--format=%B')
    .replace(/^ref-hash: .*$/m, '')
    .trim();
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

  const items = await fetchFeedItems(await fetchPublishedReleases());
  assertNewRelease(
    items.map(({ itemXml }) => itemXml),
    {
      shortVersionString: release.version,
      version: release.build,
      channel: release.channel,
    },
  );
  console.log(`✓ Build ${release.build} is above every build it is compared with in the feed`);

  if (process.env.GITHUB_OUTPUT) {
    appendFileSync(
      process.env.GITHUB_OUTPUT,
      `version=${release.version}\nbuild=${release.build}\n`,
    );
  }

  console.log(`Preflight check passed: ready to cut release ${release.version}`);
  return release;
};

/** Deletes all but the newest dev releases, with their tags. */
const pruneDevReleases = (): void => {
  const releases: { tagName: string }[] = JSON.parse(
    execFileSync(
      'gh',
      ['release', 'list', '--repo', REPOSITORY, '--limit', '1000', '--json', 'tagName'],
      { encoding: 'utf8' },
    ),
  );
  for (const tag of staleDevTags(releases.map(({ tagName }) => tagName))) {
    console.log(`Pruning dev release ${tag}...`);
    execFileSync('gh', ['release', 'delete', tag, '--cleanup-tag', '--yes', '--repo', REPOSITORY], {
      stdio: 'inherit',
    });
  }
};

/** Signs the built DMG and writes the release's appcast item beside it, as `out/appcast-item.xml`. */
const writeItem = (isDev: boolean): void => {
  const release = isDev ? resolveDevRelease() : resolveStableRelease();
  const minimumSystemVersion = getMinimumSystemVersion();
  console.log(
    `Appcast item for ${release.version} (build ${release.build}, min macOS: ${minimumSystemVersion})`,
  );

  const dmgPath = join(OUT_DIR, dmgFilenameOf(release.version));
  if (!existsSync(dmgPath)) throw new Error(`DMG not found: ${dmgPath}. Run release.sh first.`);
  const signUpdatePath = join(OUT_DIR, 'sign_update');
  if (!existsSync(signUpdatePath)) {
    throw new Error(`Sparkle's sign_update not found at ${signUpdatePath}. Run release.sh first.`);
  }
  const privateKey = process.env.SPARKLE_PRIVATE_KEY;
  if (!privateKey) throw new Error('SPARKLE_PRIVATE_KEY environment variable is required.');

  const itemXml = formatItemXml({
    channel: release.channel,
    title: `Version ${release.version}`,
    pubDate: new Date().toUTCString(),
    version: release.build,
    shortVersionString: release.version,
    minimumSystemVersion,
    releaseNotes: release.notes,
    enclosureUrl: dmgUrlOf(release.version),
    enclosureLength: statSync(dmgPath).size,
    enclosureType: 'application/x-apple-diskimage',
    edSignature: signDmg(signUpdatePath, dmgPath, privateKey),
  });
  writeFileSync(join(OUT_DIR, ITEM_ASSET), `${itemXml}\n`);
  console.log(itemXml);
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
  if (options.item) {
    writeItem(options.isDev);
    return;
  }
  if (options.pruneDev) {
    pruneDevReleases();
    return;
  }
  throw new Error('Pass --check, --item or --prune-dev.');
};

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch(error => {
    console.error(error instanceof Error ? error.message : error);
    process.exit(1);
  });
}
