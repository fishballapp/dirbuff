import { afterEach, describe, expect, it, vi } from 'vitest';
import { type AppcastReleaseItem, formatItemXml } from './appcast.ts';
import {
  dmgFilenameOf,
  dmgUrlOf,
  type FeedItem,
  feedItemOf,
  fetchFeedItems,
  type GitHubRelease,
  ITEM_ASSET,
  latestOf,
} from './feed.ts';

const itemFor = (version: string, overrides: Partial<AppcastReleaseItem> = {}): string =>
  formatItemXml({
    ...(version.includes('-dev.') ? { channel: 'dev' as const } : {}),
    title: `Version ${version}`,
    pubDate: 'Tue, 13 Oct 2026 10:57:20 GMT',
    version: '2127',
    shortVersionString: version,
    minimumSystemVersion: '14.0',
    releaseNotes: '- Notes.',
    enclosureUrl: dmgUrlOf(version),
    enclosureLength: 5951512,
    enclosureType: 'application/x-apple-diskimage',
    edSignature: 'signature==',
    ...overrides,
  });

const releaseOf = (version: string): GitHubRelease => ({
  tag_name: `v${version}`,
  draft: false,
  assets: [
    { name: dmgFilenameOf(version), browser_download_url: dmgUrlOf(version) },
    {
      name: ITEM_ASSET,
      browser_download_url: `https://github.com/fishballapp/dirbuff/releases/download/v${version}/${ITEM_ASSET}`,
    },
  ],
});

describe('feedItemOf', () => {
  it('takes the item a release carries, verbatim', () => {
    const itemXml = itemFor('0.1.5-dev.9', { version: '2127.9' });
    expect(feedItemOf(releaseOf('0.1.5-dev.9'), `${itemXml}\n`)).toEqual({
      tag: 'v0.1.5-dev.9',
      version: '0.1.5-dev.9',
      build: '2127.9',
      isDev: true,
      itemXml,
    });
  });

  it('refuses an item for another version than its tag', () => {
    expect(() => feedItemOf(releaseOf('0.1.4'), itemFor('0.1.3'))).toThrowError(
      /v0.1.4's appcast-item.xml is for version 0.1.3/,
    );
  });

  it('refuses an item whose channel is not exactly its tag’s', () => {
    expect(() => feedItemOf(releaseOf('0.1.4'), itemFor('0.1.4', { channel: 'dev' }))).toThrowError(
      /v0.1.4's appcast-item.xml has channel dev, not none/,
    );
    expect(() =>
      feedItemOf(releaseOf('0.1.5-dev.9'), itemFor('0.1.5-dev.9', { channel: undefined })),
    ).toThrowError(/has channel none, not dev/);
    const onBeta = itemFor('0.1.4').replace(
      '<sparkle:version>',
      '<sparkle:channel>beta</sparkle:channel>\n      <sparkle:version>',
    );
    expect(() => feedItemOf(releaseOf('0.1.4'), onBeta)).toThrowError(/has channel beta, not none/);
  });

  it('refuses an item with no readable pubDate', () => {
    const undated = itemFor('0.1.4').replace(/\s*<pubDate>[^<]*<\/pubDate>/, '');
    expect(() => feedItemOf(releaseOf('0.1.4'), undated)).toThrowError(/no readable pubDate/);
    expect(() =>
      feedItemOf(releaseOf('0.1.4'), itemFor('0.1.4', { pubDate: 'someday' })),
    ).toThrowError(/no readable pubDate \(someday\)/);
  });

  it('refuses an enclosure without a positive length', () => {
    expect(() =>
      feedItemOf(releaseOf('0.1.4'), itemFor('0.1.4', { enclosureLength: 0 })),
    ).toThrowError(/has no positive length \(0\)/);
    const unsized = itemFor('0.1.4').replace(/ length="\d+"/, '');
    expect(() => feedItemOf(releaseOf('0.1.4'), unsized)).toThrowError(/no positive length/);
  });

  it('refuses an item that downloads anything but its own release’s DMG', () => {
    expect(() =>
      feedItemOf(
        releaseOf('0.1.4'),
        itemFor('0.1.4', {
          enclosureUrl: 'https://dirbuff.fishball.app/releases/DirBuff-0.1.4.dmg',
        }),
      ),
    ).toThrowError(/downloads https:\/\/dirbuff.fishball.app/);
    const withoutDmg = { ...releaseOf('0.1.4'), assets: [] };
    expect(() => feedItemOf(withoutDmg, itemFor('0.1.4'))).toThrowError(/has no DirBuff-0.1.4.dmg/);
  });

  it('refuses an item with a build Sparkle can’t compare', () => {
    expect(() =>
      feedItemOf(releaseOf('0.1.4'), itemFor('0.1.4', { version: '2127-dev' })),
    ).toThrowError(/not digits and dots/);
  });
});

describe('fetchFeedItems', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('stops on a release that carries no item', async () => {
    const release = { ...releaseOf('0.1.4'), assets: releaseOf('0.1.4').assets.slice(0, 1) };
    await expect(fetchFeedItems([release])).rejects.toThrowError(/v0.1.4 has no appcast-item.xml/);
  });

  it('stops on two releases with one build', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async (url: string) => {
        const version = /\/v([^/]+)\//.exec(url)?.[1] ?? '';
        return new Response(itemFor(version));
      }),
    );
    await expect(fetchFeedItems([releaseOf('0.1.4'), releaseOf('0.1.5')])).rejects.toThrowError(
      /Build 2127 is in more than one release/,
    );
  });
});

describe('latestOf', () => {
  const item = (version: string, build: string): FeedItem => ({
    tag: `v${version}`,
    version,
    build,
    isDev: version.includes('-dev.'),
    itemXml: '',
  });

  it('names the newest stable release by build, never a dev build', () => {
    expect(
      latestOf([
        item('0.1.3', '2126'),
        item('0.1.5-dev.9', '2127.9'),
        item('0.1.10', '2140'),
        item('0.1.4', '2127'),
      ]),
    ).toEqual({ version: '0.1.10', url: dmgUrlOf('0.1.10') });
  });

  it('refuses a feed with no stable release', () => {
    expect(() => latestOf([item('0.1.5-dev.9', '2127.9')])).toThrowError(/No stable release/);
  });
});
