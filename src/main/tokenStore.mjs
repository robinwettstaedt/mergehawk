import fs from "node:fs/promises";

export function createFileTokenStore({
  filePath,
  readFile = (path) => fs.readFile(path, "utf8"),
  writeFile = (path, value) => fs.writeFile(path, value, "utf8"),
  rm = (path) => fs.rm(path, { force: true }),
  encrypt,
  decrypt
}) {
  async function get() {
    try {
      const encrypted = await readFile(filePath);
      if (!encrypted) {
        return null;
      }
      return JSON.parse(decrypt(encrypted));
    } catch (error) {
      if (error?.code === "ENOENT") {
        return null;
      }
      if (String(error?.message ?? "").includes("undefined")) {
        return null;
      }
      return null;
    }
  }

  async function set(record) {
    await writeFile(filePath, encrypt(JSON.stringify(record)));
  }

  async function clear() {
    await rm(filePath);
  }

  return {
    get,
    set,
    clear
  };
}
