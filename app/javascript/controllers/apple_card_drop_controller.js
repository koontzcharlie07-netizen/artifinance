import { Controller } from "@hotwired/stimulus";

// Apple Card statements dropped anywhere on the page (or picked in the file dialog)
// are uploaded at once; one line per file says what happened.
export default class extends Controller {
  static targets = ["zone", "input", "results", "done"];
  static values = { url: String };
  static classes = ["dropping"];

  dragOver(event) {
    if (!this.#hasFiles(event)) return;
    event.preventDefault();
    this.zoneTarget.classList.add(...this.droppingClasses);
  }

  dragLeave(event) {
    if (event.relatedTarget) return;
    this.zoneTarget.classList.remove(...this.droppingClasses);
  }

  drop(event) {
    if (!this.#hasFiles(event)) return;
    event.preventDefault();
    this.zoneTarget.classList.remove(...this.droppingClasses);
    this.#upload(event.dataTransfer.files);
  }

  pick() {
    this.#upload(this.inputTarget.files);
    this.inputTarget.value = "";
  }

  async #upload(fileList) {
    const files = Array.from(fileList || []);
    if (files.length === 0) return;

    const body = new FormData();
    for (const file of files) body.append("files[]", file);
    const pending = this.#line(
      `Importing ${files.length} file${files.length > 1 ? "s" : ""}…`,
      "text-secondary",
    );

    try {
      const response = await fetch(this.urlValue, {
        method: "POST",
        headers: {
          Accept: "application/json",
          "X-CSRF-Token": document.querySelector('[name="csrf-token"]')
            ?.content,
        },
        body,
      });
      const data = await response.json();
      pending.remove();
      if (!response.ok) {
        this.#line(data.error || "The import failed.", "text-destructive");
        return;
      }
      for (const result of data.results) {
        if (result.error) {
          this.#line(`${result.file}: ${result.error}`, "text-destructive");
        } else {
          this.#line(
            `${result.label}: ${result.added} added, ${result.duplicates} already there`,
            "text-success",
          );
        }
      }
      if (data.results.some((result) => !result.error)) {
        this.doneTarget.classList.remove("hidden");
      }
    } catch (_error) {
      pending.remove();
      this.#line(
        "The import failed. Check your connection and try again.",
        "text-destructive",
      );
    }
  }

  #line(text, className) {
    const item = document.createElement("li");
    item.className = className;
    item.textContent = text;
    this.resultsTarget.appendChild(item);
    return item;
  }

  #hasFiles(event) {
    return Array.from(event.dataTransfer?.types || []).includes("Files");
  }
}
