import { test } from "node:test";
import assert from "node:assert/strict";
import { buildConnectionString } from "../src/db.js";

const DB_KEYS = ["DB_USER", "DB_PASSWORD", "DB_HOST", "DB_PORT", "DB_NAME"];

function withDbEnv(overrides, fn) {
  const saved = Object.fromEntries(DB_KEYS.map((k) => [k, process.env[k]]));
  for (const key of DB_KEYS) delete process.env[key];
  Object.assign(process.env, overrides);
  try {
    fn();
  } finally {
    for (const key of DB_KEYS) {
      if (saved[key] === undefined) delete process.env[key];
      else process.env[key] = saved[key];
    }
  }
}

test("buildConnectionString falls back to defaults when DB_* vars are unset", () => {
  withDbEnv({}, () => {
    assert.equal(
      buildConnectionString(),
      "postgres://appuser:apppass@localhost:5432/appdb"
    );
  });
});

test("buildConnectionString uses DB_* env vars when set", () => {
  withDbEnv(
    {
      DB_USER: "testuser",
      DB_PASSWORD: "testpass",
      DB_HOST: "db.internal",
      DB_PORT: "5433",
      DB_NAME: "testdb",
    },
    () => {
      assert.equal(
        buildConnectionString(),
        "postgres://testuser:testpass@db.internal:5433/testdb"
      );
    }
  );
});
