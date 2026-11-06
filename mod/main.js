import { View, div } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { agents, hc, exec, theme, appHome } from "herdr";

const backend = `${appHome()}/mods/recap-codex/backend.ps1`;

export default class CodexRecap extends View {
  init(_props, cx) {
    this.info = {};
    this.pids = {};
    this.busy = new Set();
    this.error = "";
    this.reading = false;
    this.lastRead = 0;
    this.refresh(cx);
    // A poll only reads session metadata and cached summaries; it never runs Codex.
    cx.timer.every(5000, (cx) => this.refresh(cx));
  }

  refresh(cx) {
    if (this.reading) return;
    if (!this.busy.size && Date.now() - this.lastRead < 30000) return;
    this.reading = true;
    this.lastRead = Date.now();
    cx.spawn(async (cx) => {
      try {
        const local = agents().filter((a) => a.app === "codex" && !a.address.includes("/"));
        const found = await Promise.all(local.map(async (a) => {
          const r = await hc(["get", a.address, "--json"]);
          return r.code === 0 ? [a.address, JSON.parse(r.stdout).pid] : [a.address, null];
        }));
        this.pids = Object.fromEntries(found.filter(([, pid]) => pid));
        const pids = [...new Set(Object.values(this.pids))];
        if (pids.length) {
          const r = await exec("pwsh", ["-NoProfile", "-File", backend, "inspect", pids.join(",")]);
          if (r.code !== 0) throw new Error(r.stderr.trim() || r.stdout.trim());
          const byPid = new Map(JSON.parse(r.stdout).map((x) => [x.pid, x]));
          for (const [address, pid] of Object.entries(this.pids)) {
            this.info[address] = byPid.get(pid) ?? { error: "No session information" };
            if (this.info[address].fresh || this.info[address].error) this.busy.delete(address);
          }
        }
        this.error = "";
      } catch (e) {
        this.error = String(e?.message ?? e);
      } finally {
        this.reading = false;
        cx.notify();
      }
    });
  }

  generate(address, cx) {
    const pid = this.pids[address];
    if (!pid || this.busy.has(address)) return;
    this.busy.add(address);
    this.error = "";
    cx.notify();
    cx.spawn(async (cx) => {
      try {
        const r = await exec("pwsh", ["-NoProfile", "-File", backend, "start", String(pid)]);
        if (r.code !== 0) throw new Error(r.stderr.trim() || r.stdout.trim());
        const outcome = JSON.parse(r.stdout);
        if (outcome.error) throw new Error(outcome.error);
        if (outcome.status === "cached") this.busy.delete(address);
        this.refresh(cx);
      } catch (e) {
        this.busy.delete(address);
        this.error = String(e?.message ?? e);
      }
      cx.notify();
    });
  }

  render() {
    const t = theme();
    const list = agents().filter((a) => a.app === "codex" && !a.address.includes("/"));
    const cards = list.map((a) => this.card(t, a));
    if (!cards.length) cards.push(div().text_size(13).text_color(t.muted).child("目前沒有本機 Codex agent。"));
    return v_flex().id("codex-recap").w(760).h(560).bg(t.surface).p(18).gap(12)
      .child(h_flex().items_center().gap(12)
        .child(div().text_size(19).font_semibold().text_color(t.foreground).child("Codex 摘要"))
        .child(div().text_size(12).text_color(t.muted).child("按下按鈕才會使用 Codex；開啟與瀏覽只讀快取")))
      .when(Boolean(this.error), (el) => el.child(div().text_size(12).text_color(t.accent).child(this.error)))
      .child(v_flex().flex_1().min_h(0).overflow_y_scrollbar().gap(10).children(cards));
  }

  card(t, a) {
    const i = this.info[a.address] ?? {};
    const busy = this.busy.has(a.address);
    const state = i.fresh ? "已快取" : i.recap ? "摘要已過期" : "尚無摘要";
    return v_flex().id(`recap-${a.address}`).flex_none().rounded(9).bg(t.raised).p(12).gap(8)
      .child(h_flex().items_center().gap(10)
        .child(div().flex_1().min_w(0).truncate().font_semibold().text_color(t.foreground).child(a.title || a.address))
        .child(div().text_size(11).text_color(t.muted).child(state))
        .child(div().id(`generate-${a.address}`).rounded(6).bg(t.accent).px(10).py(6)
          .cursor_pointer().on_click((_e, cx) => this.generate(a.address, cx))
          .child(div().text_size(12).text_color(t.accent_foreground).child(busy ? "產生中…" : i.fresh ? "顯示快取" : "產生／更新摘要"))))
      .child(div().text_size(13).text_color(t.foreground).child(i.recap || "按下「產生／更新摘要」後才會建立摘要。"))
      .when(Boolean(i.error), (el) => el.child(div().text_size(11).text_color(t.muted).child(i.error)));
  }
}
