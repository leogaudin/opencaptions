import assert from "node:assert/strict";
import { after, beforeEach, describe, test } from "node:test";

/** Every request the client made, and the answers to give next. */
let sent: Request[] = [];
let answers: Response[] = [];
const realFetch = globalThis.fetch;

const json = (body: unknown, status = 200): Response =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

// The client keeps the `fetch` it finds when it is made, so the stand-in is there before it is.
globalThis.fetch = (async (input: RequestInfo | URL) => {
  sent.push(input as Request);
  const answer = answers.shift();
  if (!answer) throw new Error("no answer queued");
  return answer;
}) as typeof fetch;
// A browser has an origin to resolve `/api/...` against; this test has to say one.
Object.assign(globalThis, { location: { origin: "http://localhost" } });
const api = await import("../../src/lib/api.ts");

beforeEach(() => {
  sent = [];
  answers = [];
  api.setCsrfToken(null);
  api.setUnauthorizedHandler(null);
});
after(() => {
  globalThis.fetch = realFetch;
});

describe("the typed API client", () => {
  test("a change carries the CSRF token and a read does not", async () => {
    api.setCsrfToken("tok");
    answers.push(json({ items: [], total: 0, page: 1, per_page: 20 }), json({ id: "p" }));
    await api.listProjects(2, 5);
    await api.updateProject("p", { title: "x" });
    const [read, write] = sent as [Request, Request];
    assert.equal(read.headers.get("x-csrf-token"), null);
    assert.equal(write.headers.get("x-csrf-token"), "tok");
    const url = new URL(read.url);
    assert.equal(url.pathname + url.search, "/api/v1/projects?page=2&per_page=5");
    assert.equal(write.method, "PATCH");
    assert.deepEqual(await write.json(), { title: "x" });
  });

  test("an error answer becomes an ApiException with the API's body", async () => {
    answers.push(
      json({ error: "no_video", detail: "Project has no uploaded video", code: 400 }, 400),
    );
    await assert.rejects(api.startTranscription("p"), (e: unknown) => {
      assert.ok(e instanceof api.ApiException);
      assert.equal(e.status, 400);
      assert.equal(e.body?.error, "no_video");
      assert.equal(e.message, "Project has no uploaded video");
      return true;
    });
    // Only what was chosen is sent: the API defaults the rest.
    assert.deepEqual(await sent[0]?.json(), {});
  });

  test("a 204 is nothing, and a page that is not the API's is refused", async () => {
    answers.push(new Response(null, { status: 204 }));
    assert.equal(await api.deleteProject("p"), undefined);
    answers.push(
      new Response("<html>dev server</html>", {
        status: 200,
        headers: { "content-type": "text/html" },
      }),
    );
    await assert.rejects(api.getHealth(), /Unexpected response from the server/);
  });

  test("an unexpected 401 reaches the handler, and a quiet one does not", async () => {
    let handled = 0;
    api.setUnauthorizedHandler(() => handled++);
    answers.push(json({ error: "not_authenticated", detail: "no", code: 401 }, 401));
    await assert.rejects(api.getSettings());
    assert.equal(handled, 1);
    answers.push(json({ error: "not_authenticated", detail: "no", code: 401 }, 401));
    await assert.rejects(api.fetchMe());
    answers.push(json({ error: "not_authenticated", detail: "wrong password", code: 401 }, 401));
    await assert.rejects(api.changeEmail("a@b.c", "nope"));
    assert.equal(handled, 1, "the bootstrap probe and a wrong password are not a dead session");
  });

  test("signing in keeps the CSRF token for the calls after it, and signing out drops it", async () => {
    answers.push(
      json({ user: { id: "u", email: "a@b.c" }, csrf_token: "fresh" }),
      new Response(null, { status: 204 }),
      new Response(null, { status: 204 }),
    );
    await api.login("a@b.c", "pw");
    await api.deleteProject("p");
    assert.equal(sent[1]?.headers.get("x-csrf-token"), "fresh");
    await api.logout();
    await api.logout().catch(() => undefined);
  });

  test("a project made from a link is sent as a form", async () => {
    answers.push(json({ id: "p" }));
    await api.createProjectFromUrl("clip", "https://example.com/v.mp4");
    const request = sent[0] as Request;
    assert.match(request.headers.get("content-type") ?? "", /multipart\/form-data/);
    const form = await request.formData();
    assert.equal(form.get("title"), "clip");
    assert.equal(form.get("video_url"), "https://example.com/v.mp4");
  });
});
