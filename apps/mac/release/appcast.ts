export type AppcastReleaseItem = {
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

export const formatItemXml = (release: AppcastReleaseItem, indent = '    '): string => {
  const lines = [
    `${indent}<item>`,
    `${indent}  <title>${escapeXml(release.title)}</title>`,
    `${indent}  <pubDate>${escapeXml(release.pubDate)}</pubDate>`,
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
 * number above every build in it (Sparkle compares builds, not the version people see).
 */
export const assertNewRelease = (
  existingXml: string | null,
  release: Pick<AppcastReleaseItem, 'shortVersionString' | 'version'>,
): void => {
  const existingItems = existingXml === null ? [] : extractItems(existingXml);
  for (const itemXml of existingItems) {
    const { shortVersionString, version } = extractItemVersions(itemXml);
    if (shortVersionString === release.shortVersionString) {
      throw new Error(
        `Duplicate release version: "${release.shortVersionString}" is already present in appcast.`,
      );
    }
    if (version === release.version) {
      throw new Error(
        `Duplicate release build: "${release.version}" is already present in appcast.`,
      );
    }
    if (version !== null && Number(version) > Number(release.version)) {
      throw new Error(
        `Release build "${release.version}" is below build "${version}" already in the appcast, so no installed copy would be offered it. Raise CURRENT_PROJECT_VERSION in project.yml.`,
      );
    }
  }
};

export const updateAppcast = (existingXml: string | null, release: AppcastReleaseItem): string => {
  const baseXml = existingXml && existingXml.trim().length > 0 ? existingXml : createEmptyAppcast();

  assertNewRelease(baseXml, release);

  const newItemXml = formatItemXml(release);

  const firstItemIndex = baseXml.search(/<item\b/i);
  if (firstItemIndex !== -1) {
    return `${baseXml.slice(0, firstItemIndex)}${newItemXml}\n${baseXml.slice(firstItemIndex)}`;
  }

  const closeChannelIndex = baseXml.search(/<\/channel>/i);
  if (closeChannelIndex !== -1) {
    return `${baseXml.slice(0, closeChannelIndex)}${newItemXml}\n  ${baseXml.slice(closeChannelIndex)}`;
  }

  throw new Error('Invalid appcast XML: missing </channel> tag.');
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
