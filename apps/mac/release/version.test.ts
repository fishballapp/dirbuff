import { describe, expect, it } from 'vitest';
import { compareBuilds, devCountOf, devRelease, staleDevTags } from './version.ts';

describe('compareBuilds', () => {
  it('compares segment by segment as numbers, as Sparkle does', () => {
    expect(compareBuilds('2126.20', '2126.150')).toBe(-1);
    expect(compareBuilds('2126.150', '2126.20')).toBe(1);
    expect(compareBuilds('2127', '2126.9999')).toBe(1);
  });

  it('counts a missing segment as zero', () => {
    expect(compareBuilds('2126', '2126.0')).toBe(0);
    expect(compareBuilds('2126', '2126.1')).toBe(-1);
    expect(compareBuilds('2126.1', '2126')).toBe(1);
  });

  it('refuses anything but digits and dots', () => {
    expect(() => compareBuilds('2126-dev', '1')).toThrowError(/not digits and dots/);
  });
});

describe('devRelease', () => {
  it('builds above the stable build it follows and below the next', () => {
    const dev = devRelease({ marketingVersion: '0.1.3', build: '2126', commitCount: 150 });
    expect(dev).toEqual({ version: '0.1.4-dev.150', build: '2126.150' });
    expect(compareBuilds(dev.build, '2126')).toBe(1);
    expect(compareBuilds(dev.build, '2127')).toBe(-1);
  });

  it('grows with the commit count even across digit counts', () => {
    const at = (commitCount: number) =>
      devRelease({ marketingVersion: '0.1.3', build: '2126', commitCount }).build;
    expect(compareBuilds(at(99), at(100))).toBe(-1);
    expect(compareBuilds(at(150), at(1000))).toBe(-1);
  });

  it('refuses a marketing version that is not three numbers', () => {
    expect(() =>
      devRelease({ marketingVersion: '0.1', build: '2126', commitCount: 1 }),
    ).toThrowError(/not <major>.<minor>.<patch>/);
  });
});

describe('devCountOf', () => {
  it('reads the count of a dev version or tag only', () => {
    expect(devCountOf('0.1.4-dev.150')).toBe(150);
    expect(devCountOf('v0.1.4-dev.150')).toBe(150);
    expect(devCountOf('v0.1.4')).toBeNull();
    expect(devCountOf('v0.1.4-beta.1')).toBeNull();
  });
});

describe('staleDevTags', () => {
  const tag = (count: number) => `v0.1.4-dev.${count}`;

  it('names every dev tag but the newest three, by commit count', () => {
    const tags = ['v0.1.3', tag(148), tag(152), tag(9), tag(151), tag(150)];
    expect(staleDevTags(tags)).toEqual([tag(148), tag(9)]);
  });

  it('never names a stable tag, and nothing while three or fewer dev tags exist', () => {
    expect(staleDevTags(['v0.1.2', 'v0.1.3', tag(150), tag(151), tag(152)])).toEqual([]);
  });
});
