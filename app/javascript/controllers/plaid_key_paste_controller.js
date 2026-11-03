import { Controller } from "@hotwired/stimulus";

// Plaid keys pasted on the onboarding screen, in any order, one at a time or together. As soon as both a
// client ID (24 hex characters) and a secret (30) are in the box, they are checked with Plaid; when they
// work, Plaid Link opens in the modal frame so the bank can be picked straight away.
export default class extends Controller {
  static targets = ["input", "clientId", "secret", "message"];
  static values = { url: String, checking: String };

  pasted() {
    // Let the pasted text land in the box first.
    window.setTimeout(() => this.changed(), 0);
  }

  changed() {
    const tokens = (this.inputTarget.value.match(/[0-9a-zA-Z]{16,}/g) || [])
      .map((token) => token.toLowerCase())
      .filter((token) => /^[0-9a-f]+$/.test(token));
    const hasClientId = tokens.some((token) => token.length === 24);
    const hasSecret = tokens.some((token) => token.length === 30);
    this.#mark(this.clientIdTarget, hasClientId);
    this.#mark(this.secretTarget, hasSecret);

    const signature = tokens.join(" ");
    if (
      signature &&
      signature !== this.lastChecked &&
      (hasClientId || hasSecret)
    ) {
      window.clearTimeout(this.timer);
      this.timer = window.setTimeout(
        () => this.#check(signature),
        hasClientId && hasSecret ? 0 : 1200,
      );
    }
  }

  async #check(signature) {
    this.lastChecked = signature;
    this.#say(this.checkingValue, "text-secondary");
    try {
      const response = await fetch(this.urlValue, {
        method: "POST",
        headers: {
          Accept: "application/json",
          "Content-Type": "application/json",
          "X-CSRF-Token": document.querySelector('[name="csrf-token"]')
            ?.content,
        },
        body: JSON.stringify({ keys: this.inputTarget.value }),
      });
      const data = await response.json();
      this.#say(data.message, data.ok ? "text-success" : "text-destructive");
      if (data.ok) {
        this.inputTarget.disabled = true;
        const modal = document.getElementById("modal");
        if (modal) modal.src = data.link_url;
      }
    } catch (_error) {
      this.lastChecked = null;
      this.#say(
        "We couldn't reach Plaid just now. Wait a minute and paste again.",
        "text-destructive",
      );
    }
  }

  #mark(target, found) {
    target.classList.toggle("text-success", found);
    target.classList.toggle("text-secondary", !found);
    const icon = target.querySelector("svg");
    if (icon) icon.style.opacity = found ? "1" : "0.4";
    target.dataset.found = found ? "true" : "false";
  }

  #say(text, className) {
    this.messageTarget.textContent = text;
    this.messageTarget.className = `text-base font-medium ${className}`;
  }
}
