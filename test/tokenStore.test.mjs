import test from "node:test";
import assert from "node:assert/strict";
import { createFileTokenStore } from "../src/main/tokenStore.mjs";

test("stores and reads encrypted token records", async () => {
  const files = new Map();
  const store = createFileTokenStore({
    filePath: "/tmp/auth.json",
    readFile: async (path) => files.get(path),
    writeFile: async (path, value) => files.set(path, value),
    rm: async (path) => files.delete(path),
    encrypt: (value) => Buffer.from(value, "utf8").toString("base64"),
    decrypt: (value) => Buffer.from(value, "base64").toString("utf8")
  });

  await store.set({ accessToken: "gho_token", login: "rw", scope: "repo,read:user" });

  assert.equal(files.get("/tmp/auth.json").includes("gho_token"), false);
  assert.deepEqual(await store.get(), {
    accessToken: "gho_token",
    login: "rw",
    scope: "repo,read:user"
  });
});

test("clears stored token records", async () => {
  const files = new Map([["/tmp/auth.json", "enc:{}"]]);
  const store = createFileTokenStore({
    filePath: "/tmp/auth.json",
    readFile: async (path) => files.get(path),
    writeFile: async (path, value) => files.set(path, value),
    rm: async (path) => files.delete(path),
    encrypt: (value) => Buffer.from(value, "utf8").toString("base64"),
    decrypt: (value) => Buffer.from(value, "base64").toString("utf8")
  });

  await store.clear();

  assert.equal(await store.get(), null);
});
