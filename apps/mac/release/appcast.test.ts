import { describe, expect, it } from 'vitest';
import {
  type AppcastReleaseItem,
  assertNewRelease,
  createAppcast,
  extractChangelogSection,
  extractEnclosure,
  extractItems,
  extractItemVersions,
  formatItemXml,
} from './appcast.ts';

const sampleRelease: AppcastReleaseItem = {
  title: 'Version 0.1.0',
  pubDate: 'Fri, 10 Oct 2026 14:00:00 GMT',
  version: '1',
  shortVersionString: '0.1.0',
  minimumSystemVersion: '14.0',
  releaseNotes: '## 0.1.0\n\n- Initial release with right-click Temporary tag.',
  enclosureUrl: 'https://dirbuff.fishball.app/releases/DirBuff-0.1.0.dmg',
  enclosureLength: 1234567,
  enclosureType: 'application/x-apple-diskimage',
  edSignature: 'mockSignatureBase64==',
};

/** The feed of `releases`, as feed.ts builds it from the items the releases carry. */
const feedOf = (...releases: AppcastReleaseItem[]): string =>
  createAppcast(releases.map(formatItemXml));

describe('appcast logic', () => {
  it('writes every field of an item into the feed', () => {
    const xml = feedOf(sampleRelease);

    expect(xml).toContain('<?xml version="1.0" encoding="utf-8"?>');
    expect(xml).toContain(
      '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"',
    );
    expect(xml).toContain('<title>DirBuff</title>');
    expect(xml).toContain('<sparkle:shortVersionString>0.1.0</sparkle:shortVersionString>');
    expect(xml).toContain('<sparkle:version>1</sparkle:version>');
    expect(xml).toContain('<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>');
    expect(xml).toContain(
      '<description sparkle:format="markdown"><![CDATA[## 0.1.0\n\n- Initial release with right-click Temporary tag.]]></description>',
    );
    expect(extractEnclosure(xml)).toEqual({
      url: 'https://dirbuff.fishball.app/releases/DirBuff-0.1.0.dmg',
      length: '1234567',
      edSignature: 'mockSignatureBase64==',
    });
    expect(xml).toContain('length="1234567"');

    const items = extractItems(xml);
    expect(items).toHaveLength(1);
    expect(extractItemVersions(items[0]!)).toEqual({
      shortVersionString: '0.1.0',
      version: '1',
    });
  });

  it('lists the items newest build first, segment by segment, whatever order they come in', () => {
    const build = (version: string): AppcastReleaseItem => ({ ...sampleRelease, version });
    const xml = feedOf(build('2126'), build('2126.150'), build('2127'), build('2126.20'));

    expect(extractItems(xml).map(item => extractItemVersions(item).version)).toEqual([
      '2127',
      '2126.150',
      '2126.20',
      '2126',
    ]);
    expect(xml).toMatch(/<language>en<\/language>\n {4}<item>/);
    expect(xml).toMatch(/<\/item>\n {2}<\/channel>/);
  });

  it('indents an item it is handed with stray whitespace like any other', () => {
    const xml = createAppcast([`\n\t  ${formatItemXml(sampleRelease)}\n\n`]);
    expect(xml).toMatch(/<language>en<\/language>\n {4}<item>\n {6}<title>/);
    expect(xml).toMatch(/ {4}<\/item>\n {2}<\/channel>/);
  });

  it('refuses a duplicate version (shortVersionString)', () => {
    expect(() =>
      assertNewRelease([formatItemXml(sampleRelease)], { ...sampleRelease, version: '99' }),
    ).toThrowError(/Duplicate release version: "0.1.0"/);
  });

  it('refuses a duplicate build number (version)', () => {
    expect(() =>
      assertNewRelease([formatItemXml(sampleRelease)], {
        ...sampleRelease,
        shortVersionString: '0.1.1',
      }),
    ).toThrowError(/Duplicate release build: "1"/);
  });

  it('refuses a build number below one already in the feed, which Sparkle would never offer', () => {
    const items = [formatItemXml({ ...sampleRelease, version: '2125' })];

    expect(() =>
      assertNewRelease(items, { shortVersionString: '0.1.1', version: '3' }),
    ).toThrowError(/build "3" is below build "2125"/);
    expect(() =>
      assertNewRelease(items, { shortVersionString: '0.1.1', version: '2126' }),
    ).not.toThrow();
  });

  it('escapes XML entities in metadata and attributes', () => {
    const xml = formatItemXml({
      ...sampleRelease,
      title: 'DirBuff <Special> & "Edition"\'s Update',
      enclosureUrl: 'https://dirbuff.fishball.app/releases/DirBuff-0.1.1.dmg?foo=1&bar=2',
    });
    expect(xml).toContain(
      '<title>DirBuff &lt;Special&gt; &amp; &quot;Edition&quot;&apos;s Update</title>',
    );
    expect(xml).toContain(
      'url="https://dirbuff.fishball.app/releases/DirBuff-0.1.1.dmg?foo=1&amp;bar=2"',
    );
  });

  it('escapes CDATA termination tokens in release notes', () => {
    const xml = formatItemXml({
      ...sampleRelease,
      releaseNotes: 'Some notes with raw closing token: ]]> here and another ]]> here.',
    });
    expect(xml).not.toContain(']]> here');
    expect(xml).toContain(
      '<description sparkle:format="markdown"><![CDATA[Some notes with raw closing token: ]]]]><![CDATA[> here and another ]]]]><![CDATA[> here.]]></description>',
    );
  });
  it('extracts changelog section for a specific version', () => {
    const changelog = `# Changelog

## 0.2.0

- Added something in 0.2.0.

## 0.1.0

Initial public release of DirBuff for macOS:

- Make any Finder folder Temporary.
- Four automated cleanup rules.

## 0.0.1

- Internal alpha.
`;

    const section010 = extractChangelogSection(changelog, '0.1.0');
    expect(section010).toBe(`Initial public release of DirBuff for macOS:

- Make any Finder folder Temporary.
- Four automated cleanup rules.`);

    const section020 = extractChangelogSection(changelog, '0.2.0');
    expect(section020).toBe('- Added something in 0.2.0.');

    expect(() => extractChangelogSection(changelog, '9.9.9')).toThrowError(
      /Section "## 9.9.9" not found in CHANGELOG/,
    );
  });

  describe('dev builds', () => {
    const stable = (version: string, build: string): AppcastReleaseItem => ({
      ...sampleRelease,
      title: `Version ${version}`,
      shortVersionString: version,
      version: build,
    });
    const dev = (count: number, build = `2126.${count}`): AppcastReleaseItem => ({
      ...sampleRelease,
      channel: 'dev',
      title: `Version 0.1.4-dev.${count}`,
      shortVersionString: `0.1.4-dev.${count}`,
      version: build,
    });

    it('writes the dev channel on a dev item and on no stable one', () => {
      const [devItem, stableItem] = extractItems(feedOf(stable('0.1.3', '2126'), dev(150)));
      expect(devItem).toContain('<sparkle:channel>dev</sparkle:channel>');
      expect(stableItem).not.toContain('<sparkle:channel>');
    });

    it('compares builds segment by segment, not as one number', () => {
      const items = [formatItemXml(dev(150))];
      expect(() => assertNewRelease(items, dev(20))).toThrowError(
        /build "2126.20" is below build "2126.150"/,
      );
      expect(() => assertNewRelease(items, dev(151))).not.toThrow();
    });

    it('refuses a dev build below a stable one, but not a stable build below a dev one', () => {
      const withStable = [formatItemXml(stable('0.1.3', '2126'))];
      expect(() => assertNewRelease(withStable, dev(150, '2125.150'))).toThrowError(
        /is below build/,
      );

      const withDev = [...withStable, formatItemXml(dev(150))];
      expect(() => assertNewRelease(withDev, stable('0.1.4', '2127'))).not.toThrow();
      expect(() => assertNewRelease(withDev, stable('0.1.4', '2126'))).toThrowError(
        /Duplicate release build|below/,
      );
    });

    it('lets a stable release follow the dev build of the commit that bumped its version', () => {
      const items = [stable('0.1.3', '2126'), dev(151, '2127.151')].map(formatItemXml);
      expect(() => assertNewRelease(items, stable('0.1.4', '2127'))).not.toThrow();
    });

    it('refuses a stable build below a stable one already in the feed', () => {
      expect(() =>
        assertNewRelease([formatItemXml(stable('0.1.3', '2126'))], stable('0.1.4', '2125')),
      ).toThrowError(/is below build/);
    });
  });
});
