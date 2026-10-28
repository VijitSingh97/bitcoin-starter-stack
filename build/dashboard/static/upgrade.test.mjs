import { test } from "node:test";
import assert from "node:assert/strict";

class Element extends EventTarget {
  constructor(tagName = "div") {
    super();
    this.tagName = tagName;
    this.children = [];
    this.hidden = true;
    this.disabled = false;
    this.attributes = new Map();
    this._text = "";
  }

  set textContent(value) {
    this._text = value;
    this.children = [];
  }

  get textContent() {
    return this._text + this.children.map((child) => child.textContent).join("");
  }

  appendChild(child) {
    this.children.push(child);
    return child;
  }

  setAttribute(name, value) {
    this.attributes.set(name, value);
  }
}

function nextTurn() {
  return new Promise((resolve) => setImmediate(resolve));
}

test("upgrade control survives live dashboard replacement and keeps pending state", async () => {
  const window = new EventTarget();
  const document = {
    box: new Element(),
    getElementById(id) { return id === "upgrade" ? this.box : null; },
    createElement(tagName) { return new Element(tagName); },
    createTextNode(text) { return { textContent: text }; },
  };
  let pending = false;
  const fetch = async (_url, options = {}) => {
    if (options.method === "POST") {
      pending = true;
      return { ok: true };
    }
    return {
      json: async () => ({
        enabled: true,
        update: "stack v1.3.0 available (running v1.2.0)",
        pending,
      }),
    };
  };

  Object.assign(globalThis, {
    document,
    window,
    fetch,
    setInterval() {},
  });
  await import(`./upgrade.js?test=${Date.now()}`);
  await nextTurn();

  assert.equal(document.box.hidden, false);
  assert.equal(document.box.children.at(-1)?.textContent, "Upgrade now");

  document.box = new Element();
  window.dispatchEvent(new Event("live-updated"));
  await nextTurn();
  const button = document.box.children.at(-1);
  assert.equal(button?.textContent, "Upgrade now");

  button.dispatchEvent(new Event("click"));
  await nextTurn();
  assert.match(document.box.textContent, /Upgrade requested/);

  window.dispatchEvent(new Event("live-updated"));
  await nextTurn();
  assert.match(document.box.textContent, /Upgrade requested/);
  assert.equal(document.box.children.length, 0);
});
