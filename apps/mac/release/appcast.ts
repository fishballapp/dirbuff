import { compareBuilds } from './version.ts';

/** A stable release has no channel: every copy is offered it. A dev build is offered only to those who chose `dev`. */
export type ReleaseChannel = 'dev';

export type AppcastReleaseItem = {
  readonly channel?: ReleaseChannel;
  readonly title: string;
  readonly pubDate: string;
  readonly version: string;
  readonly shortVersionString: string;
  readonly minimumSystemVersion: string;
  readonly releaseNotes: string;
  readonly enclosureUrl: string;
  readonly enclosureLength: number;
  readonly enclosureType: string;
  readonly edSignature: string;
};

export const escapeXml = (value: string): string =>
  value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

export const escapeCdata = (value: string): string => value.replaceAll(']]>', ']]]]><![CDATA[>');

export const extractItems = (xml: string): string[] => {
  const matches = xml.match(/<item\b[\s\S]*?<\/item>/gi);
  return matches ? [...matches] : [];
};

export const extractItemVersions = (
  itemXml: string,
): { shortVersionString: string | null; version: string | null } => {
  const shortVersionMatch = itemXml.match(
    /<sparkle:shortVersionString[^>]*>([^<]+)<\/sparkle:shortVersionString>/i,
  );
  const versionMatch = itemXml.match(/<sparkle:version[^>]*>([^<]+)<\/sparkle:version>/i);
  const enclosureVersionMatch = itemXml.match(/sparkle:version="([^"]+)"/i);
  const enclosureShortVersionMatch = itemXml.match(/sparkle:shortVersionString="([^"]+)"/i);

  return {
    shortVersionString:
      (shortVersionMatch ? shortVersionMatch[1]?.trim() : null) ??
      (enclosureShortVersionMatch ? enclosureShortVersionMatch[1]?.trim() : null) ??
      null,
    version:
      (versionMatch ? versionMatch[1]?.trim() : null) ??
      (enclosureVersionMatch ? enclosureVersionMatch[1]?.trim() : null) ??
      null,
  };
};

/** The item's channel as written, any name; `undefined` for an item with none (a stable release). */
export const extractItemChannel = (itemXml: string): string | undefined =>
  itemXml.match(/<sparkle:channel>([^<]+)<\/sparkle:channel>/i)?.[1]?.trim();

export const extractPubDate = (itemXml: string): string | null =>
  itemXml.match(/<pubDate>([^<]+)<\/pubDate>/i)?.[1]?.trim() ?? null;

/** The update an item names: its download, its size, and the EdDSA signature Sparkle checks. */
export const extractEnclosure = (
  itemXml: string,
): { url: string | null; length: string | null; edSignature: string | null } => {
  const enclosure = itemXml.match(/<enclosure\b[^>]*>/i)?.[0] ?? '';
  return {
    url: enclosure.match(/\burl="([^"]+)"/)?.[1] ?? null,
    length: enclosure.match(/\blength="([^"]+)"/)?.[1] ?? null,
    edSignature: enclosure.match(/\bsparkle:edSignature="([^"]+)"/)?.[1] ?? null,
  };
};

/** One item, as its release carries it; `createAppcast` indents its first line. */
export const formatItemXml = (release: AppcastReleaseItem): string => {
  const indent = '    ';
  const lines = [
    '<item>',
    `${indent}  <title>${escapeXml(release.title)}</title>`,
    `${indent}  <pubDate>${escapeXml(release.pubDate)}</pubDate>`,
    ...(release.channel === undefined
      ? []
      : [`${indent}  <sparkle:channel>${escapeXml(release.channel)}</sparkle:channel>`]),
    `${indent}  <sparkle:version>${escapeXml(release.version)}</sparkle:version>`,
    `${indent}  <sparkle:shortVersionString>${escapeXml(release.shortVersionString)}</sparkle:shortVersionString>`,
    `${indent}  <sparkle:minimumSystemVersion>${escapeXml(release.minimumSystemVersion)}</sparkle:minimumSystemVersion>`,
    `${indent}  <description sparkle:format="markdown"><![CDATA[${escapeCdata(release.releaseNotes)}]]></description>`,
    `${indent}  <enclosure url="${escapeXml(release.enclosureUrl)}" length="${release.enclosureLength}" type="${escapeXml(release.enclosureType)}" sparkle:edSignature="${escapeXml(release.edSignature)}" />`,
    `${indent}</item>`,
  ];
  return lines.join('\n');
};

/**
 * Throws unless `release` is one Sparkle would offer: a version the feed doesn't have, and a build
 * above the builds it is compared with (Sparkle compares builds, not the version people see). A
 * dev build is compared with every item; a stable one with the stable items only, so the dev build
 * of the commit that bumped the version (`2127.151`) doesn't block the release of `2127`.
 */
export const assertNewRelease = (
  existingItems: readonly string[],
  release: Pick<AppcastReleaseItem, 'shortVersionString' | 'version' | 'channel'>,
): void => {
  for (const itemXml of existingItems) {
    const { shortVersionString, version } = extractItemVersions(itemXml);
    if (shortVersionString === release.shortVersionString) {
      throw new Error(
        `Duplicate release version: "${release.shortVersionString}" is already present in appcast.`,
      );
    }
    if (version === null) continue;

    const order = compareBuilds(version, release.version);
    if (order === 0) {
      throw new Error(
        `Duplicate release build: "${release.version}" is already present in appcast.`,
      );
    }
    const isCompared = release.channel === 'dev' || extractItemChannel(itemXml) === undefined;
    if (isCompared && order > 0) {
      throw new Error(
        `Release build "${release.version}" is below build "${version}" already in the appcast, so no installed copy would be offered it. Raise CURRENT_PROJECT_VERSION in project.yml.`,
      );
    }
  }
};

/**
 * The feed: every item, newest build first, as Sparkle reads it. Each item is the one its release
 * carries, verbatim, so its EdDSA signature and date are what the release job wrote.
 */
export const createAppcast = (items: readonly string[]): string => {
  const newestFirst = items
    .map(itemXml => {
      const { version } = extractItemVersions(itemXml);
      if (version === null) throw new Error(`An appcast item has no build:\n${itemXml}`);
      return { itemXml: itemXml.trim(), build: version };
    })
    .toSorted((a, b) => compareBuilds(b.build, a.build));
  return `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>DirBuff</title>
    <link>https://dirbuff.fishball.app/appcast.xml</link>
    <description>Most recent changes with links to updates.</description>
    <language>en</language>
${newestFirst.map(({ itemXml }) => `    ${itemXml}\n`).join('')}  </channel>
</rss>
`;
};

export const extractChangelogSection = (changelogContent: string, version: string): string => {
  const lines = changelogContent.split(/\r?\n/);
  const targetHeader = `## ${version}`;
  const bracketHeader = `## [${version}]`;

  let capturing = false;
  const sectionLines: string[] = [];

  for (const line of lines) {
    if (capturing) {
      if (line.startsWith('## ')) {
        break;
      }
      sectionLines.push(line);
    } else {
      const trimmed = line.trim();
      if (
        trimmed === targetHeader ||
        trimmed.startsWith(`${targetHeader} `) ||
        trimmed === bracketHeader ||
        trimmed.startsWith(`${bracketHeader} `)
      ) {
        capturing = true;
      }
    }
  }

  if (!capturing) {
    throw new Error(`Section "## ${version}" not found in CHANGELOG.`);
  }

  const section = sectionLines.join('\n').trim();
  if (section.length === 0) {
    throw new Error(`Section "## ${version}" in CHANGELOG is empty.`);
  }
  return section;
};
