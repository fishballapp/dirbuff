#!/usr/bin/env node
import { mkdirSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { parseArgs } from 'node:util';
import * as Schema from 'effect/Schema';
import {
  createAppcast,
  extractEnclosure,
  extractItemChannel,
  extractItemVersions,
  extractPubDate,
} from './appcast.ts';
import { compareBuilds, devCountOf, isBuild } from './version.ts';

// The update feed is derived from the GitHub releases and nothing else: each release carries its
// own appcast item beside its DMG, and this script gathers them into `appcast.xml` (what Sparkle
// reads) and `latest.json` (where the site's /download goes). feed.yml deploys both to GitHub
// Pages whenever the releases change.

export const REPOSITORY = 'fishballapp/dirbuff';
/** The asset every release carries beside its DMG: its own appcast item, signature included. */
export const ITEM_ASSET = 'appcast-item.xml';

export const releaseTag = (version: string): string => `v${version}`;
export const dmgFilenameOf = (version: string): string => `DirBuff-${version}.dmg`;
export const dmgUrlOf = (version: string): string =>
  `https://github.com/${REPOSITORY}/releases/download/${releaseTag(version)}/${dmgFilenameOf(version)}`;

const GitHubReleaseSchema = Schema.Struct({
  tag_name: Schema.String,
  draft: Schema.Boolean,
  assets: Schema.Array(Schema.Struct({ name: Schema.String, browser_download_url: Schema.String })),
});
export type GitHubRelease = typeof GitHubReleaseSchema.Type;
const decodeReleases = Schema.decodeUnknownSync(Schema.Array(GitHubReleaseSchema));

const PAGE_SIZE = 100;

/**
 * Every release anyone can download from, page by page. A draft's assets aren't public, so an item
 * from one would offer an update nobody can install.
 */
export const fetchPublishedReleases = async (): Promise<GitHubRelease[]> => {
  const token = process.env.GITHUB_TOKEN ?? process.env.GH_TOKEN;
  const releases: GitHubRelease[] = [];
  for (let page = 1; ; page++) {
    const res = await fetch(
      `https://api.github.com/repos/${REPOSITORY}/releases?per_page=${PAGE_SIZE}&page=${page}`,
      {
        headers: {
          accept: 'application/vnd.github+json',
          'user-agent': 'dirbuff-feed',
          ...(token === undefined ? {} : { authorization: `Bearer ${token}` }),
        },
      },
    );
    // A failed read must fail the run: a feed built from part of the releases would take updates
    // away from installed copies.
    if (!res.ok) throw new Error(`GitHub's releases API answered ${res.status} ${res.statusText}`);
    const batch = decodeReleases(await res.json());
    releases.push(...batch);
    if (batch.length < PAGE_SIZE) return releases.filter(release => !release.draft);
  }
};

export type FeedItem = {
  readonly tag: string;
  readonly version: string;
  readonly build: string;
  readonly isDev: boolean;
  readonly itemXml: string;
};

/**
 * `itemXml` as the feed item of `release`, or a throw naming what's wrong. An item that names
 * another version, another channel than its tag, or a DMG the release doesn't carry would offer
 * an update that can't be installed, and one with no date or size one Sparkle mishandles (a lapsed
 * licence is offered the newest item dated within its paid period), so it stops the feed rather
 * than reaching it.
 */
export const feedItemOf = (release: GitHubRelease, itemXml: string): FeedItem => {
  const tag = release.tag_name;
  const { shortVersionString: version, version: build } = extractItemVersions(itemXml);
  if (version === null || build === null) {
    throw new Error(`${tag}'s ${ITEM_ASSET} has no version or no build.`);
  }
  if (releaseTag(version) !== tag) {
    throw new Error(`${tag}'s ${ITEM_ASSET} is for version ${version}.`);
  }
  if (!isBuild(build)) {
    throw new Error(`${tag}'s ${ITEM_ASSET} has build "${build}", not digits and dots.`);
  }
  const isDev = devCountOf(tag) !== null;
  // Exactly: Sparkle offers an item on a channel nobody chose to no one, and one with none to all.
  const channel = extractItemChannel(itemXml);
  const expectedChannel = isDev ? 'dev' : undefined;
  if (channel !== expectedChannel) {
    throw new Error(
      `${tag}'s ${ITEM_ASSET} has channel ${channel ?? 'none'}, not ${expectedChannel ?? 'none'}.`,
    );
  }
  const pubDate = extractPubDate(itemXml);
  // RFC 822, as Sparkle reads it; Temporal parses no such format.
  if (pubDate === null || Number.isNaN(Date.parse(pubDate))) {
    throw new Error(`${tag}'s ${ITEM_ASSET} has no readable pubDate (${pubDate}).`);
  }
  const { url, length, edSignature } = extractEnclosure(itemXml);
  if (length === null || !/^[1-9]\d*$/.test(length)) {
    throw new Error(`${tag}'s ${ITEM_ASSET} has no positive length (${length}).`);
  }
  if (url !== dmgUrlOf(version)) {
    throw new Error(`${tag}'s ${ITEM_ASSET} downloads ${url}, not ${dmgUrlOf(version)}.`);
  }
  if (!release.assets.some(asset => asset.name === dmgFilenameOf(version))) {
    throw new Error(`${tag} has no ${dmgFilenameOf(version)} for its item to download.`);
  }
  if (edSignature === null) throw new Error(`${tag}'s ${ITEM_ASSET} has no EdDSA signature.`);
  return { tag, version, build, isDev, itemXml: itemXml.trim() };
};

/** The item every release carries. A release without one stops the feed: it was published wrong. */
export const fetchFeedItems = async (releases: readonly GitHubRelease[]): Promise<FeedItem[]> => {
  const items = await Promise.all(
    releases.map(async release => {
      const asset = release.assets.find(({ name }) => name === ITEM_ASSET);
      if (asset === undefined) throw new Error(`${release.tag_name} has no ${ITEM_ASSET}.`);
      // No token: the asset CDN has no business seeing it.
      const res = await fetch(asset.browser_download_url, {
        headers: { 'user-agent': 'dirbuff-feed' },
      });
      if (!res.ok) {
        throw new Error(
          `${release.tag_name}'s ${ITEM_ASSET} answered ${res.status} ${res.statusText}`,
        );
      }
      return feedItemOf(release, await res.text());
    }),
  );
  const builds = new Set<string>();
  for (const { tag, build } of items) {
    if (builds.has(build)) throw new Error(`Build ${build} is in more than one release (${tag}).`);
    builds.add(build);
  }
  return items;
};

/** `latest.json`: the newest stable release by build, which the site's /download redirects to. */
export const latestOf = (items: readonly FeedItem[]): { version: string; url: string } => {
  const [newest] = items
    .filter(({ isDev }) => !isDev)
    .toSorted((a, b) => compareBuilds(b.build, a.build));
  if (newest === undefined) {
    throw new Error('No stable release: /download would have nowhere to go.');
  }
  return { version: newest.version, url: dmgUrlOf(newest.version) };
};

const main = async () => {
  const { values } = parseArgs({ options: { out: { type: 'string' } }, strict: true });
  if (values.out === undefined) throw new Error('--out <directory> is required');
  const outDir = resolve(values.out);

  const items = await fetchFeedItems(await fetchPublishedReleases());
  const latest = latestOf(items);
  mkdirSync(outDir, { recursive: true });
  writeFileSync(join(outDir, 'appcast.xml'), createAppcast(items.map(({ itemXml }) => itemXml)));
  writeFileSync(join(outDir, 'latest.json'), `${JSON.stringify(latest, null, 2)}\n`);
  console.log(
    `Wrote ${items.length} items (${items.filter(({ isDev }) => isDev).length} dev) and latest ${latest.version} to ${outDir}`,
  );
};

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch(error => {
    console.error(error instanceof Error ? error.message : error);
    process.exit(1);
  });
}
