export const PRICE_URL = "/api/prices";
export const FIAT_CURRENCIES = ["USD", "EUR", "GBP", "INR", "CAD", "AUD", "JPY", "RUB", "CNY"];

const STORAGE_KEY = "btc-price-currency";
const POLL_MS = 60000;

export function normalizeCurrency(value) {
  const currency = String(value || "").toUpperCase();
  return FIAT_CURRENCIES.includes(currency) ? currency : "USD";
}

export function storageKey(asset = "bitcoin") {
  return asset === "monero" ? "monero-price-currency" : STORAGE_KEY;
}

export function priceURL(asset = "bitcoin") {
  return asset === "monero" ? `${PRICE_URL}?asset=monero` : PRICE_URL;
}

export function loadCurrency(storage = browserStorage(), asset = "bitcoin") {
  try {
    return normalizeCurrency(storage?.getItem(storageKey(asset)));
  } catch {
    return "USD";
  }
}

export function saveCurrency(value, storage = browserStorage(), asset = "bitcoin") {
  const currency = normalizeCurrency(value);
  try {
    storage?.setItem(storageKey(asset), currency);
  } catch {
    // The selector still works for this page when storage is unavailable.
  }
  return currency;
}

export function formatPrice(amount, currency, NumberFormat = Intl.NumberFormat) {
  const value = Number(amount);
  const code = normalizeCurrency(currency);
  try {
    return new NumberFormat(undefined, { style: "currency", currency: code }).format(value);
  } catch {
    return `${code} ${value.toFixed(code === "JPY" ? 0 : 2)}`;
  }
}

export function priceView(data, currency, formatTime = defaultTime) {
  const code = normalizeCurrency(currency);
  const amount = Number(data?.prices?.[code.toLowerCase()]);
  if (data?.available !== true || !Number.isFinite(amount) || amount <= 0) {
    return { currency: code, value: "—", status: "Price unavailable", stale: false };
  }
  const updated = Number(data.updated_at);
  const asOf = Number.isFinite(updated) && updated > 0 ? formatTime(updated) : "unknown";
  return {
    currency: code,
    value: formatPrice(amount, code),
    status: data.stale ? `Stale · as of ${asOf}` : `As of ${asOf}`,
    stale: !!data.stale,
  };
}

function browserStorage() {
  return typeof localStorage === "undefined" ? null : localStorage;
}

function defaultTime(unixSeconds) {
  const date = new Date(unixSeconds * 1000);
  try {
    return new Intl.DateTimeFormat(undefined, {
      dateStyle: "medium",
      timeStyle: "short",
    }).format(date);
  } catch {
    return date.toISOString();
  }
}

if (typeof document !== "undefined") {
  for (const widget of document.querySelectorAll("[data-price-asset]")) {
    const asset = widget.dataset.priceAsset;
    const value = widget.querySelector("[data-price-value]");
    const currencySelect = widget.querySelector("[data-price-currency]");
    const status = widget.querySelector("[data-price-status]");
    if (!value || !currencySelect || !status) continue;
    for (const code of FIAT_CURRENCIES) {
      const option = document.createElement("option");
      option.value = option.textContent = code;
      currencySelect.append(option);
    }

    let currency = loadCurrency(browserStorage(), asset);
    let latest = { available: false };
    currencySelect.value = currency;

    const render = () => {
      const view = priceView(latest, currency);
      value.textContent = view.value;
      status.textContent = view.status;
      status.classList.toggle("stale", view.stale);
      widget.hidden = false;
    };

    currencySelect.addEventListener("change", () => {
      currency = saveCurrency(currencySelect.value, browserStorage(), asset);
      currencySelect.value = currency;
      render();
    });

    const refresh = async () => {
      try {
        const response = await fetch(priceURL(asset), {
          headers: { Accept: "application/json" },
          credentials: "same-origin",
        });
        if (!response.ok) throw new Error("price request failed");
        latest = await response.json();
      } catch {
        latest = { available: false };
      }
      render();
    };

    render();
    refresh();
    setInterval(refresh, POLL_MS);
  }
}
