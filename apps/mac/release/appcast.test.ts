import { describe, expect, it } from 'vitest';
import {
  type AppcastReleaseItem,
  assertNewRelease,
  extractChangelogSection,
  extractItems,
  extractItemVersions,
  updateAppcast,
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

describe('appcast logic', () => {
  it('creates a new feed from scratch when existing XML is null or empty', () => {
    const xml = updateAppcast(null, sampleRelease);

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
    expect(xml).toContain('sparkle:edSignature="mockSignatureBase64=="');
    expect(xml).toContain('url="https://dirbuff.fishball.app/releases/DirBuff-0.1.0.dmg"');
    expect(xml).toContain('length="1234567"');

    const items = extractItems(xml);
    expect(items).toHaveLength(1);
    expect(extractItemVersions(items[0]!)).toEqual({
      shortVersionString: '0.1.0',
      version: '1',
    });
  });

  it('adds a new item to an existing feed with newest first and older items kept', () => {
    const initialXml = updateAppcast(null, sampleRelease);

    const secondRelease: AppcastReleaseItem = {
      title: 'Version 0.2.0',
      pubDate: 'Sat, 11 Oct 2026 10:00:00 GMT',
      version: '2',
      shortVersionString: '0.2.0',
      minimumSystemVersion: '14.0',
      releaseNotes: '## 0.2.0\n\n- Added new automated rule.',
      enclosureUrl: 'https://dirbuff.fishball.app/releases/DirBuff-0.2.0.dmg',
      enclosureLength: 1234999,
      enclosureType: 'application/x-apple-diskimage',
      edSignature: 'secondSignatureBase64==',
    };

    const updatedXml = updateAppcast(initialXml, secondRelease);
    const items = extractItems(updatedXml);

    expect(items).toHaveLength(2);
    expect(extractItemVersions(items[0]!)).toEqual({
      shortVersionString: '0.2.0',
      version: '2',
    });
    expect(extractItemVersions(items[1]!)).toEqual({
      shortVersionString: '0.1.0',
      version: '1',
    });

    const index020 = updatedXml.indexOf('Version 0.2.0');
    const index010 = updatedXml.indexOf('Version 0.1.0');
    expect(index020).toBeGreaterThan(-1);
    expect(index010).toBeGreaterThan(-1);
    expect(index020).toBeLessThan(index010);
  });

  it('refuses a duplicate version (shortVersionString)', () => {
    const initialXml = updateAppcast(null, sampleRelease);

    const duplicateVersionRelease: AppcastReleaseItem = {
      ...sampleRelease,
      title: 'Version 0.1.0 rebuild',
      version: '99',
    };

    expect(() => updateAppcast(initialXml, duplicateVersionRelease)).toThrowError(
      /Duplicate release version: "0.1.0"/,
    );
  });

  it('refuses a duplicate build number (version)', () => {
    const initialXml = updateAppcast(null, sampleRelease);

    const duplicateBuildRelease: AppcastReleaseItem = {
      ...sampleRelease,
      title: 'Version 0.1.1',
      shortVersionString: '0.1.1',
      version: '1',
    };

    expect(() => updateAppcast(initialXml, duplicateBuildRelease)).toThrowError(
      /Duplicate release build: "1"/,
    );
  });

  it('refuses a build number below one already in the feed, which Sparkle would never offer', () => {
    const initialXml = updateAppcast(null, { ...sampleRelease, version: '2125' });

    const lowerBuildRelease: AppcastReleaseItem = {
      ...sampleRelease,
      title: 'Version 0.1.1',
      shortVersionString: '0.1.1',
      version: '3',
    };

    expect(() => updateAppcast(initialXml, lowerBuildRelease)).toThrowError(
      /build "3" is below build "2125"/,
    );
    expect(() =>
      assertNewRelease(initialXml, { shortVersionString: '0.1.1', version: '2126' }),
    ).not.toThrow();
  });

  it('escapes XML entities in metadata and attributes', () => {
    const releaseWithSpecialChars: AppcastReleaseItem = {
      ...sampleRelease,
      title: 'DirBuff <Special> & "Edition"\'s Update',
      shortVersionString: '0.1.1',
      version: '2',
      enclosureUrl: 'https://dirbuff.fishball.app/releases/DirBuff-0.1.1.dmg?foo=1&bar=2',
    };

    const xml = updateAppcast(null, releaseWithSpecialChars);
    expect(xml).toContain(
      '<title>DirBuff &lt;Special&gt; &amp; &quot;Edition&quot;&apos;s Update</title>',
    );
    expect(xml).toContain(
      'url="https://dirbuff.fishball.app/releases/DirBuff-0.1.1.dmg?foo=1&amp;bar=2"',
    );
  });

  it('escapes CDATA termination tokens in release notes', () => {
    const releaseWithCdataBreaker: AppcastReleaseItem = {
      ...sampleRelease,
      releaseNotes: 'Some notes with raw closing token: ]]> here and another ]]> here.',
    };

    const xml = updateAppcast(null, releaseWithCdataBreaker);
    expect(xml).not.toContain(']]> here');
    expect(xml).toContain(']]]]><![CDATA[> here');
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
});
