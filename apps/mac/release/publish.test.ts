import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { writeAppcast } from './publish.ts';

type Call = { method: string; headers: Record<string, string>; body?: string };

/** An R2 whose feed is `feed`; the first `lostRaces` PUTs answer 412 and swap in a newer feed. */
const stubR2 = ({ feed, lostRaces = 0 }: { feed: string | null; lostRaces?: number }) => {
  const calls: Call[] = [];
  let current = feed;
  let revision = 1;
  let races = lostRaces;
  vi.stubGlobal(
    'fetch',
    vi.fn(async (_url: string, init: Call) => {
      calls.push(init);
      if (init.method === 'GET') {
        return current === null
          ? new Response('', { status: 404 })
          : new Response(current, { status: 200, headers: { etag: `"rev${revision}"` } });
      }
      if (races > 0) {
        races -= 1;
        revision += 1;
        current = `${current ?? ''}<!-- another run -->`;
        return new Response('', { status: 412 });
      }
      current = init.body ?? null;
      return new Response('', { status: 200 });
    }),
  );
  return calls;
};

const puts = (calls: Call[]) => calls.filter(({ method }) => method === 'PUT');

describe('writeAppcast', () => {
  beforeEach(() => {
    vi.stubEnv('R2_ACCESS_KEY_ID', 'key');
    vi.stubEnv('R2_SECRET_ACCESS_KEY', 'secret');
  });
  afterEach(() => {
    vi.unstubAllGlobals();
    vi.unstubAllEnvs();
  });

  it('writes only if the feed is the one it read, and signs that condition', async () => {
    const calls = stubR2({ feed: '<feed/>' });

    await writeAppcast('appcast.xml', existing => `${existing}<item/>`);

    const [put] = puts(calls);
    expect(put?.headers['if-match']).toBe('"rev1"');
    expect(put?.headers.Authorization).toMatch(/SignedHeaders=[^,]*\bif-match\b/);
  });

  it('reads the feed as stored, so its ETag is the strong one a write can quote', async () => {
    const calls = stubR2({ feed: '<feed/>' });

    await writeAppcast('appcast.xml', existing => `${existing}<item/>`);

    const [get] = calls.filter(({ method }) => method === 'GET');
    expect(get?.headers['accept-encoding']).toBe('identity');
  });

  it('creates the feed only if it is still absent', async () => {
    const calls = stubR2({ feed: null });

    await writeAppcast('appcast.xml', existing => `${existing ?? 'new'}<item/>`);

    const [put] = puts(calls);
    expect(put?.headers['if-none-match']).toBe('*');
    expect(put?.headers.Authorization).toMatch(/SignedHeaders=[^,]*\bif-none-match\b/);
  });

  it('reads the feed again and re-applies its change after a lost race', async () => {
    const calls = stubR2({ feed: '<feed/>', lostRaces: 2 });

    const written = await writeAppcast('appcast.xml', existing => `${existing}<item/>`);

    expect(written).toBe('<feed/><!-- another run --><!-- another run --><item/>');
    expect(calls.map(({ method }) => method)).toEqual(['GET', 'PUT', 'GET', 'PUT', 'GET', 'PUT']);
    expect(puts(calls).map(({ headers }) => headers['if-match'])).toEqual([
      '"rev1"',
      '"rev2"',
      '"rev3"',
    ]);
  });

  it('gives up when the feed never stops changing', async () => {
    stubR2({ feed: '<feed/>', lostRaces: 99 });

    await expect(
      writeAppcast('appcast.xml', existing => `${existing}<item/>`),
    ).rejects.toThrowError(/gave up after 5 attempts/);
  });
});
