# Adding your own tool to OpenDesk

OpenDesk is a native iOS shell for self-hosted, open-source business tools. Each tool is a **connector**: a small REST client plus a few SwiftUI screens. If your team runs something that isn't here yet (Twenty, Plane, Zammad, Uptime Kuma, Baserow, Directus, Cal.com…), fork this repo and ask your coding agent:

> Add an OpenDesk connector for **<tool>** at **<url>**. Follow AGENTS.md.

This file is written for that agent.

## The pattern (copy an existing module)

| Step | Where | Look at |
|---|---|---|
| 1. Client | `OpenDesk/<Tool>/<Tool>Client.swift` | `Metabase/MetabaseClient.swift` is the smallest complete example |
| 2. Screens | `OpenDesk/<Tool>/<Tool>Views.swift` | a list screen → a detail screen; reuse `card()`, `Chip`, `ErrorCard`, `AskSheet` |
| 3. Settings | `Core/AppConfig.swift` + `Home/SettingsView.swift` | add `<tool>URL` / `<tool>Token` with `didSet` persistence and a Section |
| 4. Tab | `App/OpenDeskApp.swift` | add a `RootTab` case, a `Tab(...)`, a tint, and an `opendesk://<tool>` deep link |
| 5. Home | `Home/HomeView.swift` | add a `connector(...)` tile and a `load<Tool>()` that sets its live dot |
| 6. Teams | `Teams/Supabase.swift` | add the fields to `publish` / `pull` and a column to `team_connections` so admins can share the setup |
| 7. AI | your detail screen | give `AskSheet` a `context` closure that returns **numbers and names, not pixels**, trimmed to `AI.contextBudget(config)` |

### Rules that keep the app coherent

- **Talk to the tool's existing API.** No proxy, no OpenDesk server. Tokens stay on the device (or in the team's RLS-protected row).
- **Parse loosely.** Use `JSONValue` for anything whose shape depends on user data; only model what the screens need.
- **Tables-shaped data? Don't write new screens.** Implement `TableSource` (see `NocoTableSource` and `Supabase/SupabaseApp.swift → SupabaseTableSource`) and you get list, drag-and-drop board, insights charts, the typed editor and natural-language edits for free. Map your field types onto NocoDB `uidt` names (`SingleSelect`, `Currency`, `Date`, …).
- **Charts are native.** Prefer Swift Charts from raw data over server-rendered images; fall back to images only when the data isn't reachable.
- **AI is private by default.** `AI.ask` uses on-device Apple Intelligence (4K-token window) unless the user adds a Claude key. Keep context compact.
- **Brand color**: add `static let <tool> = Color(...)` in an `extension Brand` next to your views.

## Build and run

```bash
xcodegen generate
xcodebuild -project OpenDesk.xcodeproj -scheme OpenDesk -destination 'generic/platform=iOS Simulator' build
```

New `.swift` files need `xcodegen generate` before they compile. For a device, set your own `DEVELOPMENT_TEAM` in `project.yml`.

## Verify before you call it done

1. Point the connector at a real instance (most of these tools ship a Docker image; many have public demo servers).
2. Launch in the simulator and open the new tab: the list loads, a detail screen loads, and the Home tile shows a green dot.
3. Ask the ✦ sheet one question and check that the answer cites real values from the screen.
