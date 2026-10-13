import { compareBuilds } from './version.ts';

/** A stable release has no channel: every copy is offered it. A dev build is offered only to those who chose `dev`. */
export type ReleaseChannel = 'dev';

/** The newest dev items the feed keeps, matching the GitHub releases kept. */
export const KEPT_DEV_ITEMS = 3;

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

export const createEmptyAppcast = (metadata?: {
  readonly title?: string;
  readonly link?: string;
  readonly description?: string;
  readonly language?: string;
}): string => {
  const title = metadata?.title ?? 'DirBuff';
  const link = metadata?.link ?? 'https://dirbuff.fishball.app/appcast.xml';
  const description = metadata?.description ?? 'Most recent changes with links to updates.';
  const language = metadata?.language ?? 'en';

  return `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>${escapeXml(title)}</title>
    <link>${escapeXml(link)}</link>
    <description>${escapeXml(description)}</description>
    <language>${escapeXml(language)}</language>
  </channel>
</rss>
`;
};

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

export const extractItemChannel = (itemXml: string): ReleaseChannel | undefined =>
  itemXml.match(/<sparkle:channel>([^<]+)<\/sparkle:channel>/i)?.[1]?.trim() === 'dev'
    ? 'dev'
    : undefined;

export const formatItemXml = (release: AppcastReleaseItem, indent = '    '): string => {
  const lines = [
    `${indent}<item>`,
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
  existingXml: string | null,
  release: Pick<AppcastReleaseItem, 'shortVersionString' | 'version' | 'channel'>,
): void => {
  const existingItems = existingXml === null ? [] : extractItems(existingXml);
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

const removeItem = (xml: string, itemXml: string): string => {
  const end = xml.indexOf(itemXml) + itemXml.length;
  const start = xml.slice(0, end - itemXml.length).replace(/[ \t]*$/, '').length;
  return `${xml.slice(0, start)}${xml.slice(end).replace(/^\n/, '')}`;
};

/** The dev items of `xml`, newest build first. */
const devItemsOf = (xml: string): { itemXml: string; build: string }[] =>
  extractItems(xml)
    .filter(itemXml => extractItemChannel(itemXml) === 'dev')
    .flatMap(itemXml => {
      const { version } = extractItemVersions(itemXml);
      return version === null ? [] : [{ itemXml, build: version }];
    })
    .sort((a, b) => compareBuilds(b.build, a.build));

/** The versions of the dev items in `xml`, newest first. */
export const devVersionsOf = (xml: string): string[] =>
  devItemsOf(xml).flatMap(({ itemXml }) => {
    const { shortVersionString } = extractItemVersions(itemXml);
    return shortVersionString === null ? [] : [shortVersionString];
  });

/** `xml` without any dev item beyond the newest `KEPT_DEV_ITEMS`. Stable items are never removed. */
export const pruneDevItems = (xml: string): string =>
  devItemsOf(xml)
    .slice(KEPT_DEV_ITEMS)
    .reduce((pruned, { itemXml }) => removeItem(pruned, itemXml), xml);

const insertItem = (xml: string, newItemXml: string): string => {
  const firstItemIndex = xml.search(/<item\b/i);
  if (firstItemIndex !== -1) {
    const lineStart = xml.lastIndexOf('\n', firstItemIndex) + 1;
    return `${xml.slice(0, lineStart)}${newItemXml}\n${xml.slice(lineStart)}`;
  }

  const closeChannelIndex = xml.search(/<\/channel>/i);
  if (closeChannelIndex !== -1) {
    return `${xml.slice(0, closeChannelIndex)}${newItemXml}\n  ${xml.slice(closeChannelIndex)}`;
  }

  throw new Error('Invalid appcast XML: missing </channel> tag.');
};

export const updateAppcast = (existingXml: string | null, release: AppcastReleaseItem): string => {
  const baseXml = existingXml && existingXml.trim().length > 0 ? existingXml : createEmptyAppcast();

  assertNewRelease(baseXml, release);

  const withRelease = insertItem(baseXml, formatItemXml(release));
  return release.channel === 'dev' ? pruneDevItems(withRelease) : withRelease;
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
