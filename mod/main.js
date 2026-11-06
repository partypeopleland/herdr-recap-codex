import { View, div, svg } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { agents, terminals, hc, exec, theme, appHome } from "herdr";

const backend = `${appHome()}/mods/recap-codex/backend.ps1`;
const SNAPSHOT = "recap-codex-last-read-v3";
const supportedAgents = new Set(["codex"]);
const pad2 = (n) => String(n).padStart(2, "0");

function cacheTime(value) {
  if (!value) return "";
  const d = new Date(value);
  if (Number.isNaN(d.getTime())) return "";
  return `${d.getFullYear()}/${pad2(d.getMonth() + 1)}/${pad2(d.getDate())} ${pad2(d.getHours())}:${pad2(d.getMinutes())}`;
}

export default class CodexRecap extends View {
  init(_props, cx) {
    this.info = {};
    this.pids = {};
    this.busy = new Set();
    this.error = "";
    this.reading = false;
    this.lastRead = 0;
    this.restoreSnapshot();
    this.refresh(cx);
    // A poll only reads session metadata and cached summaries; it never runs Codex.
    cx.timer.every(5000, (cx) => this.refresh(cx));
  }

  restoreSnapshot() {
    let saved;
    try { saved = JSON.parse(localStorage.getItem(SNAPSHOT) ?? "{}"); } catch { return; }
    const turns = new Map(terminals().map((t) => [t.address, t.turn]));
    const local = agents().filter((a) => supportedAgents.has(a.app) && !a.address.includes("/"));
    let complete = local.length > 0;
    for (const a of local) {
      const prior = saved[a.address];
      if (prior?.seq === a.seq && prior.title === a.title && prior.turn === turns.get(a.address) && prior.info?.session) {
        this.info[a.address] = prior.info;
      } else {
        complete = false;
      }
    }
    // A verified snapshot needs no process scan just to open the popup.
    if (complete) this.lastRead = Date.now();
  }

  saveSnapshot(local, turnsAtStart) {
    const live = new Map(agents().map((a) => [a.address, a]));
    const turns = new Map(terminals().map((t) => [t.address, t.turn]));
    const saved = {};
    for (const a of local) {
      const current = live.get(a.address);
      const turn = turnsAtStart.get(a.address);
      if (current?.seq === a.seq && current.title === a.title && turns.get(a.address) === turn && this.info[a.address]?.session) {
        saved[a.address] = { seq: a.seq, title: a.title, turn, info: this.info[a.address] };
      }
    }
    localStorage.setItem(SNAPSHOT, JSON.stringify(saved));
  }

  refresh(cx) {
    if (this.reading) return;
    if (!this.busy.size && Date.now() - this.lastRead < 30000) return;
    this.reading = true;
    this.lastRead = Date.now();
    cx.spawn(async (cx) => {
      try {
        const local = agents().filter((a) => supportedAgents.has(a.app) && !a.address.includes("/"));
        const turnsAtStart = new Map(terminals().map((t) => [t.address, t.turn]));
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
        this.saveSnapshot(local, turnsAtStart);
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
    if (this.busy.has(address)) return;
    this.busy.add(address);
    this.error = "";
    cx.notify();
    cx.spawn(async (cx) => {
      try {
        const terminal = await hc(["get", address, "--json"]);
        if (terminal.code !== 0) throw new Error(terminal.stderr.trim() || "找不到 agent 終端");
        const pid = JSON.parse(terminal.stdout).pid;
        if (!pid) throw new Error("找不到 agent 行程");
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
    const list = agents().filter((a) => supportedAgents.has(a.app) && !a.address.includes("/"));
    const cards = list.map((a) => this.card(t, a));
    if (!cards.length) cards.push(div().text_size(13).text_color(t.muted).child("目前沒有本機 Codex agent。"));
    return v_flex().id("codex-recap").w(760).h(560).bg(t.surface).p(18).gap(12)
      .child(h_flex().items_center().gap(12)
        .child(div().text_size(19).font_semibold().text_color(t.foreground).child("Recap"))
        .child(div().text_size(12).text_color(t.muted).child("按下刷新才會產生摘要；開啟與瀏覽只讀快取")))
      .when(Boolean(this.error), (el) => el.child(div().text_size(12).text_color(t.accent).child(this.error)))
      .child(v_flex().flex_1().min_h(0).overflow_y_scrollbar().gap(10).children(cards));
  }

  card(t, a) {
    const i = this.info[a.address] ?? {};
    const busy = this.busy.has(a.address);
    const time = i.at_local || cacheTime(i.at);
    return v_flex().id(`recap-${a.address}`).flex_none().rounded(9).bg(t.raised).p(12).gap(8)
      .child(h_flex().items_center().gap(10)
        .child(div().flex_1().min_w(0).truncate().font_semibold().text_color(t.foreground).child(a.title || a.address))
        .child(div().flex_none().rounded(5).bg(t.surface).px(7).py(3).text_size(10).text_color(t.muted).child(a.app || "codex"))
        .when(Boolean(i.recap && !i.fresh), (el) => el.child(div().flex_none().size(8).rounded_full().bg(t.ansi2).tooltip("摘要後有新對話")))
        .when(Boolean(time), (el) => el.child(div().flex_none().text_size(11).text_color(t.muted).child(time)))
        .child(div().id(`generate-${a.address}`).flex_none().rounded(6).bg(t.surface).p(7)
          .cursor_pointer().hover((el) => el.bg(t.hover))
          .tooltip(busy ? "產生中…" : i.fresh ? "摘要已是最新" : "產生／更新摘要（使用 Codex）")
          .on_click((_e, cx) => this.generate(a.address, cx))
          .child(svg("mods/recap-codex/icons/refresh.svg").size(15).text_color(t.foreground).when(busy, (el) => el.spin(900)))))
      .child(div().text_size(13).text_color(t.foreground).child(i.recap || "按下右上角刷新圖示產生摘要。"))
      .when(Boolean(i.error), (el) => el.child(div().text_size(11).text_color(t.muted).child(i.error)));
  }
}
