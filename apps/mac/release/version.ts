const segmentsOf = (build: string): number[] => {
  if (!/^\d+(\.\d+)*$/.test(build)) throw new Error(`Build "${build}" is not digits and dots.`);
  return build.split('.').map(Number);
};

/**
 * Sparkle's `SUStandardVersionComparator` for the digits-and-dots builds we ship: segment by
 * segment as numbers, a missing segment counting as 0 (so `2126` < `2126.20` < `2126.150` < `2127`).
 */
export const compareBuilds = (a: string, b: string): number => {
  const [segmentsA, segmentsB] = [segmentsOf(a), segmentsOf(b)];
  const length = Math.max(segmentsA.length, segmentsB.length);
  for (let i = 0; i < length; i++) {
    const difference = (segmentsA[i] ?? 0) - (segmentsB[i] ?? 0);
    if (difference !== 0) return Math.sign(difference);
  }
  return 0;
};

/**
 * What a build of public `main` calls itself. `commitCount` only grows, so a later commit is a
 * higher build; the build sits above the stable one it follows (`<build>.<count>` > `<build>`) and
 * below the next stable build, and the version people see names the release it is heading for.
 */
export const devRelease = ({
  marketingVersion,
  build,
  commitCount,
}: {
  readonly marketingVersion: string;
  readonly build: string;
  readonly commitCount: number;
}): { readonly version: string; readonly build: string } => {
  const match = /^(\d+)\.(\d+)\.(\d+)$/.exec(marketingVersion);
  if (match === null) {
    throw new Error(`MARKETING_VERSION "${marketingVersion}" is not <major>.<minor>.<patch>.`);
  }
  const [major, minor, patch] = match.slice(1).map(Number);
  return {
    version: `${major}.${minor}.${(patch ?? 0) + 1}-dev.${commitCount}`,
    build: `${build}.${commitCount}`,
  };
};

/** The commit count of a dev version or tag (`0.1.4-dev.150`, `v0.1.4-dev.150`), or null for any other. */
export const devCountOf = (versionOrTag: string): number | null => {
  const match = /^v?\d+\.\d+\.\d+-dev\.(\d+)$/.exec(versionOrTag);
  return match?.[1] === undefined ? null : Number(match[1]);
};

/**
 * The dev release tags to delete once the feed keeps `keptTags`: the dev tags among `tags` that it
 * doesn't keep and that are older than the newest it does. A dev release newer than that is a run
 * still publishing, and any other tag is a stable release.
 */
export const staleDevTags = (tags: readonly string[], keptTags: readonly string[]): string[] => {
  const newestKept = Math.max(-1, ...keptTags.map(tag => devCountOf(tag) ?? -1));
  return tags.filter(tag => {
    const count = devCountOf(tag);
    return count !== null && count < newestKept && !keptTags.includes(tag);
  });
};
