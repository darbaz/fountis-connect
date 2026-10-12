import "./dom.mjs";
import { afterEach, beforeEach, describe, it } from "node:test";
import assert from "node:assert/strict";
import { onEvent, setUserToken, show, signOut, start } from "../src/index";
import { API, ENGINE_URL, fakeApi, fakeClock, flush, resetPage, teaser, track, q } from "./helpers.mjs";

// The token provider rules of protocol/CONTRACT.md "Token provider outcomes", as the web SDK keeps them.

let clock;
let events;
let off;
beforeEach(() => {
  resetPage();
  clock = fakeClock();
  events = [];
  off = onEvent((e) => events.push(e.type));
  start({ key: "pk_test_x", apiBase: API, engineUrl: ENGINE_URL });
});
afterEach(() => {
  off();
  signOut();
  clock.restore();
  resetPage();
});

/** The guest path is open on this app, so any wrongly-signed-out person WOULD get a teaser. */
const guestsAllowed = () => fakeApi({ guests: true });

describe("token provider timeout", () => {
  it("gives noFill after 10 s, never a guest, and releases the SDK for the next show()", async () => {
    const calls = guestsAllowed();
    let asked = 0;
    setUserToken(() => {
      asked++;
      return new Promise(() => {}); // never answers
    });
    const r = track(show());
    await flush();
    assert.equal(asked, 1);

    await clock.tick(9_999);
    assert.equal(r.settled, false, "still waiting at 9.999 s");

    await clock.tick(1);
    assert.equal(await r.done, "noFill");
    assert.deepEqual(calls, [], "no request at all: not the surveys, not a guest session");
    assert.equal(teaser(), undefined, "no teaser");
    assert.deepEqual(events, ["noFill"]);

    // The provider is asked again: the timed-out call did not leave the SDK busy.
    const again = track(show());
    await flush();
    assert.equal(asked, 2);
    await clock.tick(10_000);
    assert.equal(await again.done, "noFill");
  });

  it("accepts an answer that arrives just inside the 10 s", async () => {
    guestsAllowed();
    setUserToken(() => new Promise((resolve) => setTimeout(() => resolve(null), 9_000)));
    const r = track(show());
    await flush();
    await clock.tick(9_000);
    assert.ok(teaser(), "null after 9 s is a signed-out person: the guest teaser shows");
    q(teaser(), ".no").click();
    assert.equal(await r.done, "dismissed");
  });
});

describe("failures are never a guest", () => {
  const failures = {
    "a provider that throws": () => {
      throw new Error("no network");
    },
    "a provider that rejects": async () => {
      throw new Error("401 from my server");
    },
  };
  for (const [name, provider] of Object.entries(failures)) {
    it(`${name} shows nothing`, async () => {
      const calls = guestsAllowed();
      setUserToken(provider);
      assert.equal(await show(), "noFill");
      assert.deepEqual(calls, []);
      assert.equal(teaser(), undefined);
    });
  }
});

describe('an empty token ("") is not signed out', () => {
  it("from a function gives noFill and never a guest", async () => {
    const calls = guestsAllowed();
    setUserToken(() => "");
    assert.equal(await show(), "noFill");
    assert.deepEqual(calls, [], "no guest session, no survey list");
    assert.equal(teaser(), undefined);
  });

  it("from an async function gives noFill and never a guest", async () => {
    const calls = guestsAllowed();
    setUserToken(async () => "");
    assert.equal(await show(), "noFill");
    assert.deepEqual(calls, []);
    assert.equal(teaser(), undefined);
  });

  it("passed directly as the token gives noFill and never a guest", async () => {
    const calls = guestsAllowed();
    setUserToken("");
    assert.equal(await show(), "noFill");
    assert.deepEqual(calls, []);
    assert.equal(teaser(), undefined);
  });
});

describe("only null or undefined is signed out", () => {
  for (const [name, value] of [["null", null], ["undefined", undefined]]) {
    it(`${name} shows the guest studies when the app allows guests`, async () => {
      const calls = guestsAllowed();
      setUserToken(() => value);
      const r = track(show());
      await flush();
      assert.ok(teaser(), "the guest teaser is on the page");
      assert.ok(calls.some((c) => c.path === "/guest/session"));
      q(teaser(), ".no").click();
      assert.equal(await r.done, "dismissed");
    });
  }

  it("null shows nothing when the app does not allow guests", async () => {
    fakeApi({ guests: false });
    setUserToken(() => null);
    assert.equal(await show(), "noFill");
    assert.equal(teaser(), undefined);
  });
});
