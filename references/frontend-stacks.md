# Frontend stacks — component + icon library menu

> Verified as of 2026-08-21 (live-checked: daisyUI 5.7, HeroUI on React
> Aria + Tailwind v4, PrimeVue 90+ components). **This file is a menu, not
> a verdict**: `ff-plan draft --shape app` presents these rows at the
> interactive stack question and the USER decides; the choice lands as an
> ADR in the target repo and is never re-litigated per run. Maintenance
> rule: this space moves fast — re-verify a row against its live site
> before presenting it, never recommend from memory alone.

## How to read the tables

Each row: what it is, where it shines, its honest caveat, and
fleet-relevant notes (agent corpus familiarity, ownership model, agent
instrumentation, DESIGN.md token fit). **House-stack rows outrank generic
rows**: when an org has a standing stack (recorded as an org/client ADR),
handoff legibility to the humans who inherit the code beats any generic
property below. First entry: Evolution7 Vue work → PrimeVue.

## Component libraries

| Library | What it is | Shines when | Caveat | Fleet notes |
|---|---|---|---|---|
| **shadcn/ui** (Radix + Tailwind) | Copy-in components — code lands in YOUR repo | React builds wanting ownership: components sit inside a Builder's `owns:`, editable, no upstream drift | The convergent "shadcn look" unless retokened (DESIGN.md → Tailwind export is the antidote) | Deepest agent corpus of the list — cheap lanes write it near-natively; official registry/MCP |
| **HeroUI** | Styled components on React Aria + Tailwind v4 | React builds wanting beautiful + a11y-first without owning component code | Package model: upstream controls the code (supply-chain rules apply; components not editable in-lane) | Strong agent tooling: tiered llms docs, MCP (React + Native), agent-skills |
| **React Aria Components** (Adobe) | Unstyled behaviour/a11y primitives | Fully custom design systems; when a11y depth is the bar (focus, SR, i18n, touch) | You author every pixel — pricier lanes, needs a real DESIGN.md | Exemplary docs; corpus decent; pairs with any token system |
| **PrimeVue** (PrimeTek) | Batteries-included Vue suite, 90+ components incl. the deep end (datatables, charts) | Vue builds — and any org whose humans already use it (handoff legibility) | No visible agent instrumentation (no llms.txt/MCP) — vendor API extracts into packets | WCAG-engineered; layered design-token architecture maps to DESIGN.md; styled + unstyled (Volt) lines; maintained since 2008 |
| **daisyUI** | Pure-CSS semantic classes on Tailwind, zero JS, 15+ frameworks | Server-rendered / non-React stacks (Astro, Laravel, Craft, HTMX); cheapest possible lanes | No behaviour layer — dialogs/comboboxes/focus traps need JS from elsewhere; built-in themes read *themey* | Most agent-instrumented of all: MCP server, llms.txt, Claude Code plugin; 88% fewer class names = compressed packets |
| **Mantine** | Batteries-included React (components + hooks), CSS modules | Internal tools/dashboards/admin — built well today, non-Tailwind lane | Its own styling system — outside the DESIGN.md → Tailwind export path (tokens still map, by hand) | Excellent docs; good default look; large coherent surface |
| **Ark UI** (+ Park UI styled) | Headless, state-machine driven, one API for React/Vue/Solid | Multi-framework orgs wanting ONE component vocabulary | Younger corpus than the React-only rows — route lanes a tier up | Park UI + Panda tokens map to DESIGN.md cleanly |

## Icon libraries

Pick ONE per project (mixing icon families is a classic visual-qa
finding). Same rule: user decides at the stack question, recorded in
DESIGN.md's Components/assets section.

| Library | Character | Shines when | Notes |
|---|---|---|---|
| **Lucide** | Clean 24px stroke set, the Feather lineage | Default pairing with shadcn (its house set); huge corpus, consistent grid | ISC license; tree-shakable per-icon packages for every framework |
| **Phosphor** | Very large set, SIX weights (thin→fill + duotone) | When one family must cover light UI chrome AND bold marketing moments — weight axis = hierarchy without a second family | The flexibility is the feature; pick 2 weights per project or drift follows |
| **Tabler** | 5,900+ outline icons, generous coverage | Breadth-first: dashboards and dense tools where "is there an icon for X?" must always be yes | Outline-only discipline keeps it coherent; webfont + SVG + per-framework packages |
| **Heroicons** | Small curated set (~300), outline/solid/mini/micro sizes | Tailwind-family stacks wanting the house pairing; when curation beats coverage | By the Tailwind team; micro (16px) variants are genuinely designed, not shrunk |
| **Iconoir** | 1,500+ hand-drawn-precise outline set | When the icon set itself should carry personality without going full custom | One weight, strong identity; smaller corpus — vendor the name list into packets |

## Consumption contract

- `ff-plan draft --shape app` interactive step: present component rows
  (house-stack rows first, filtered by target framework) + icon rows;
  the user's picks land as `ADR-00N: frontend stack` in the target repo
  and in DESIGN.md's front matter.
- Packets for stacks WITHOUT agent instrumentation (PrimeVue, Mantine,
  Iconoir) get vendored doc extracts in `Read first`; stacks WITH MCP /
  llms.txt (daisyUI, HeroUI, shadcn) can have that knowledge provisioned
  into worker config dirs instead (fleet-worker "giving a worker skills").
- DESIGN.md (google-labs design.md format, pinned version) remains the
  single token source regardless of pick; Tailwind-family stacks derive
  config via `design.md export`.
