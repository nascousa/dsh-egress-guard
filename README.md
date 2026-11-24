# dsh-egress-guard

![DSH Egress Guard icon](./assets/icon.png)

A DSH **profile bundle** that removes the audited egress paths a profile has to
DeepSeek infrastructure, and replaces the one capability that lives there.

Installing it applies one patch layer to the profile. Nothing is patched in the
DSH installation itself, so `git pull` in a source checkout never conflicts, and
removing the bundle restores the shipped behaviour exactly.

## Who this is for

This bundle is intended for people who want to use DSH while keeping prompts,
tool arguments, session events, and telemetry away from DeepSeek-operated
infrastructure or from a provider/jurisdiction whose data-access policy they do
not accept. That includes users concerned about possible access or disclosure
to the Chinese government. The project does **not** assert that DeepSeek or any
government actually receives DSH data; it reduces a documented network path and
provides an auditable privacy control.

The complete privacy boundary still depends on the model and search provider
chosen after installation. Blocking DeepSeek does not protect data sent to a
substitute provider, and a Zero Data Retention (ZDR) promise is not immunity
from legal process. Review the provider's contract, retention policy, training
policy, subprocessors, data region, and request/tool exceptions.

Version 0.1.2 expands the OS-level sinkhole to every DeepSeek host currently
identified in the audited DSH runtime, including account notifications, Desktop
updates, and public documentation links. It covers both the `web` and Electron
`desktop` profiles, writes IPv4 and IPv6 rules, pins the audited search
dependency, reuses the resolved local SearXNG image, and verifies effective
configuration plus DNS sinkholes.

Version 0.1.9 adds an explicit end-to-end privacy model: it identifies users
concerned about DeepSeek/jurisdictional data paths, separates route blocking
from provider privacy, and documents self-hosting and published ZDR options. It
retains the Dyson-sphere icon and previously sanitized public examples.

## What it changes

| Row | Change | Why |
|---|---|---|
| `session-log-deepseek` | `enabled: false` | Stops the `dsh_session_log` request field (up to 8 MiB of session events per request) and its session/user-id headers from riding every official DeepSeek API request. |
| `session-telemetry-otel` | `mode: DISABLED` | Constructs no OTLP coordinator, provider, processor, or exporter, leaving the shipped collector URL unreachable. |
| `plugin-package-inventory-deepseek` | unmounted | Drops the `dsh_plugin_packages` field and its headers from official requests. |
| `llm-deepseek` | unmounted | The DeepSeek API-key model route. |
| `llm-deepseek-account` | unmounted | The DeepSeek account-backed model route. |
| `deepseek-account` | unmounted | Account platform: sign-in, token exchange, profile reads against `platform.deepseek.com`. |
| `web-search-deepseek` | unmounted | Native search that posts every query to `api.deepseek.com`. |
| `plugin-manager` | `fallbackRegistries: []` | The shipped default is `[https://registry.npmmirror.com/]`: an install that cannot reach npmjs silently retried against a mirror in China. |
| `web` | `searchProvider: dsh-web-search` | Points search at the replacement provider below. |
| *(inserted)* `dsh-web-search-plugin` | `provider: tavily` | The replacement search backend. The package's own default is `deepseek-official`, so this override is what keeps queries off DeepSeek. |

**No capability is given up**, because none of the above is the only way to do
its job:

- **Compatible model weights** can be configured through alternate
  `llm-pi-ai` providers. Only DeepSeek's *own* API routes are unmounted.
  Prompts then go to the substitute provider, so use the provider-selection
  requirements below rather than selecting a vendor only because it serves the
  same weights.
- **Web search** is replaced, and works with no API key by default (see below).
- **Account sign-in** is replaced by API keys for the providers above.

## Install

From the packed tarball (the verified path):

```powershell
dsh plugin --profile web add C:\path\to\dsh-egress-guard-0.1.9.tgz
```

From a git repository you control:

```powershell
dsh plugin --profile web add https://github.com/NASCOUSA/dsh-egress-guard.git
```

## Upgrade an existing installation

A file tarball installation is a copy, not a link. Editing this project folder
does not update the package under `$DSH_HOME\profiles\<name>\node_modules`.
Upgrade an existing 0.1.0 through 0.1.8 installation with a newly packed 0.1.9
tarball:

```powershell
npm pack
dsh plugin --profile web remove dsh-egress-guard
dsh plugin --profile web add C:\path\to\dsh-egress-guard\dsh-egress-guard-0.1.9.tgz
pwsh -File scripts\verify-profile.ps1 -Profile web
```

If DSH is launched from a source checkout rather than a global `dsh` command,
pass its repository to the verifier:

```powershell
pwsh -File scripts\verify-profile.ps1 `
  -Profile web `
  -DshRepository C:\path\to\deepseek-harness
```

Restart DSH after changing an installed bundle. Source-only script and
documentation enhancements can be used immediately, but package metadata and
Cordis rows take effect only after reinstalling the bundle.

Install the same package into the Electron-owned `desktop` profile while the
Desktop application is fully closed. Use the Desktop carrier's supported
plugin-management entry point so its package-manager runtime and profile lock
are retained. The verifier supports either profile:

```powershell
pwsh -File scripts\verify-profile.ps1 `
  -Profile desktop `
  -DshRepository C:\path\to\deepseek-harness
```

### Two install methods that break, and why

Both were hit while verifying this package. Neither is hypothetical.

**Do not install from a bare local folder path.** `dsh plugin add C:\folder`
records a `link:` dependency, and pnpm does not install a linked package's own
dependencies, so `dsh-web-search-plugin` is missing and its row cannot mount —
search silently falls back to "no usable web provider". Verified: the same
package installed as a `.tgz` resolves the row; as a `link:` it does not. If you
only have a folder, run `npm pack` in it and install the `.tgz`.

**Do not install `dsh-web-search-plugin` yourself alongside this bundle.** It is
a bundle too, and its own layer inserts the same row id with
`provider: deepseek-official`. Because bundle layers apply in order and later
layers win, that second row overrides this bundle's `tavily` and sends every
query to `api.deepseek.com`. Verified: installing both packages produces two
`dsh-web-search-plugin` rows, the last one `deepseek-official`.

If you end up in that state, a profile-level override wins over both, because
the profile's own `cordis.patch.yml` applies after every bundle layer — verified
to bring the effective provider back to `tavily`. Add to
`$DSH_HOME/profiles/<name>/cordis.patch.yml`:

```yaml
- id: dsh-web-search-plugin
  config:
    provider: tavily
```

Then confirm with the dump command below that no row reads
`provider: deepseek-official`.

Then **restart `dsh`**. The bundle mounts a new module root, which a
configuration reload cannot pick up.

If `dsh-web-search-plugin` is a direct dependency of the profile only to support
this guard, remove that direct declaration and let `dsh-egress-guard` supply the
exact audited version `0.5.1`. Keep any profile-level provider override.

### Before you install

Sign out of the DeepSeek account first (Settings → Account → Sign out). This
bundle unmounts the account platform, and an unmounted platform cannot drive the
sign-out flow. Sign-out deletes the local credential before its revoke request,
and this bundle blocks neither, but the row must be mounted for the flow to run.

## After installing: point the default model somewhere else

**This step is required, not optional.** A stock profile's `agent-default-model`
row reads `provider: deepseek-official`, and this bundle unmounts that route. Left
alone, the agent has no model to run — verified: a freshly composed profile that
installs only this bundle still shows `provider: deepseek-official` in its
`agent-default-model` row.

The bundle cannot choose for you, because the substitute needs *your* API key.
Pick a provider that serves the same weights and add it as an `llm-pi-ai`
provider, then set the default model — in the Web GUI under Settings → Models, or
in `$DSH_HOME/profiles/<name>/cordis.patch.yml`:

```yaml
- id: agent-default-model
  config:
    provider: <privacy-approved provider id>
    model: <privacy-approved model id>
```

Several hosted providers can serve compatible model weights, but availability
is not a privacy endorsement. Until a provider is set, the bundle's effect is
"no model", not "a private model".

## Model provider selection is part of the privacy boundary

Installing this bundle closes the audited DeepSeek-operated routes. It cannot
make a third-party inference provider private. The provider receiving the
prompt is now the main privacy dependency, and the same applies to search
queries, file uploads, tools, and any provider-side storage or background jobs.

Prefer providers in this order:

1. **Self-host the model on infrastructure you control.** Serve an open-weight
   model locally or in your own private cloud. For an OpenAI-compatible local
   endpoint, use a server such as [vLLM](https://docs.vllm.ai/en/stable/serving/online_serving/openai_compatible_server/)
   or [Ollama in local-only mode](https://docs.ollama.com/faq). Bind the endpoint
   to loopback/private networking, disable request logging and cloud features,
   secure the reverse proxy, encrypt storage, and define log/backup deletion
   rules. Self-hosting is only as private as the telemetry, logs, backups, and
   outbound dependencies of that deployment.
2. **Use a hosted provider with an enforceable ZDR mode.** Require prompt and
   completion non-retention, no training, no human review except a narrowly
   documented exception, explicit processing regions, and a list of
   subprocessors. Set the provider's control in the organization/account; do
   not rely only on a request body flag or marketing summary.
3. **Do not treat "does not train" as sufficient.** A provider may still retain
   content for abuse review, observability, prompt caching, batch APIs, support,
   or legal compliance. Safety retention and training are separate decisions.

Public provider policies to evaluate as of **2026-11-24**:

| Provider path | Published claim or control | Required caveat |
|---|---|---|
| Relace API | [ZDR policy](https://relace.ai/old/legal/zero-data-retention-policy) says covered prompts and outputs are held only transiently and are not used for training. | Confirm the policy still covers the exact API product; metadata is retained. |
| Together AI | [ZDR](https://docs.together.ai/docs/zero-data-retention) is enabled by default for new organizations when prompt storage is off; passthrough models are unavailable with that setting. | Verify the organization setting; uploaded files and account/request metadata remain governed separately. |
| DeepInfra | [Data privacy](https://docs.deepinfra.com/account/data-privacy) says normal inference inputs and outputs are not stored to disk and are not trained on. | Google/Anthropic models and bulk/image workflows have stated exceptions; avoid them unless their separate terms are acceptable. |
| OpenRouter with ZDR | [ZDR controls](https://openrouter.ai/docs/guides/features/zdr) restrict requests to eligible endpoints; endpoint policy can differ from provider default. | Enforce **ZDR Only**, review each endpoint, and do not assume web-search/plugins or other tools inherit model-route ZDR. |
| Fireworks AI Enterprise | [Enterprise ZDR](https://docs.fireworks.ai/accounts/zero-data-retention) is account-wide and rejects supported features that persist content. | ZDR is an Enterprise feature; it does not cover third-party tools/search and has law/abuse exceptions. |
| Amazon Bedrock | [Per-region data retention modes](https://docs.aws.amazon.com/bedrock/latest/userguide/data-retention.html) include `none`; requests requiring retention are blocked. | Configure every used Region/project and verify model eligibility; `store: false` alone is not enough. |
| Microsoft Foundry models sold by Azure | [Data/privacy documentation](https://learn.microsoft.com/en-us/azure/foundry/responsible-ai/openai/data-privacy) says prompts and completions are not used for training and Azure-hosted models do not call the original model provider. | Stateful features can persist data, and abuse monitoring/human-review exceptions require review. |

These links are evidence to re-check, not a permanent approval list. Policies,
models, subprocessor routes, and jurisdictions can change. Before production
use, record the provider, endpoint/model, ZDR setting, region, contract/DPA,
policy URL, verification date, and a test showing that the effective endpoint is
the intended one.

If the requirement is "no model prompt or response leaves systems I control,"
the commercial choices above do not satisfy it. Run the model and its gateway
locally/private, disable prompt logging and analytics, and keep search/tool
execution on approved infrastructure too.

The same warning applies to search: Tavily, Exa, Brave, and other hosted search
providers receive search queries under their own policies. A self-hosted
SearXNG removes a hosted search API from the path, but SearXNG's upstream search
engines still receive queries unless it is configured with no external
backends or only approved internal indexes.

## Verify

Compose the profile without booting it and read the rows:

```powershell
dsh --profile web --dump-config
```

Every row in the table above should appear with the stated value, each preceded
by a `# == ..., patched by ...` comment naming this bundle as the source. With a
source checkout the command is
`node --import tsx/esm apps/cli/src/bin.ts --profile web --dump-config`.

For an actionable check, run:

```powershell
pwsh -File scripts\verify-profile.ps1 -Profile web
```

This verifies row cardinality, the effective disabled states, a non-DeepSeek
search and model provider, the installed guard version, and the audited
`dsh-web-search-plugin` version. It warns if the search plugin is also directly
declared by the profile.

Then check the two things that silently break the effect — a duplicate search
row, and no row at all:

```powershell
$dump = dsh --profile web --dump-config
($dump | Select-String 'id: dsh-web-search-plugin').Count          # must be 1
$dump | Select-String -Pattern 'provider: deepseek-official' -Context 0,0
```

Both commands should leave the effective profile with no
`deepseek-official` provider. If the default model still selects it, replace that
provider before using DSH; if the search row selects it, search is going to
DeepSeek.

## The network layer is a separate step

A plugin cannot do this part: it needs Administrator, and it is not DSH
configuration.

`scripts/block-deepseek-hosts.ps1` sinkholes the DeepSeek hosts identified in
the audited runtime, at the OS resolver, for both IPv4 and IPv6:

| Host | Used for |
|---|---|
| `api.deepseek.com` | model inference, tools, and native web search |
| `platform.deepseek.com` | account sign-in, token exchange, profile, and billing |
| `harness.deepseek.com` | account notifications and events |
| `harness-test.deepseek.com` | test account-notification deployment |
| `dsh-otel-collector.deepseeksvc.com` | OTLP session telemetry collector |
| `download.deepseek.com` | production Desktop updates and installers |
| `download-test.deepseek.com` | test Desktop updates and installers |
| `api-docs.deepseek.com` | DeepSeek API documentation |
| `docs.deepseek.com` | DeepSeek documentation |
| `www.deepseek.com` | DeepSeek website and public links |
| `deepseek.com` | DeepSeek root website |

```powershell
# preview (no Administrator needed)
pwsh -File scripts\block-deepseek-hosts.ps1 -DryRun
# test block parsing and idempotence
pwsh -File scripts\block-deepseek-hosts.ps1 -SelfTest
# apply (elevated)
pwsh -File scripts\block-deepseek-hosts.ps1
# undo
pwsh -File scripts\block-deepseek-hosts.ps1 -Remove
```

It writes one marked block, so it is idempotent and leaves a hosts file's other
content — including the sections Docker Desktop and Tailscale manage — alone.
An unmatched, duplicated, or reversed managed marker aborts without changing
the file.

The target list is shared with `verify-profile.ps1` through
`scripts\deepseek-targets.psd1`. The verifier checks exact IPv4/IPv6 entries and
then confirms the operating-system resolver returns sinkhole addresses for
every target.

Blocking the update hosts also prevents the Desktop application from reaching
DeepSeek's updater. Documentation links stop resolving too. This is the
intended behaviour for a no-DeepSeek-access policy.

The network layer remains name-based: a hardcoded IP, DNS-over-HTTPS, proxy
bypass, VPN tunnel, or a future hostname not present in the audited list can
bypass a hosts entry. Re-run the inventory and verifier after every DSH upgrade.

## Choosing a search backend

Edit the `dsh-web-search-plugin` row in the profile's `cordis.patch.yml` (applied
after bundle layers, so it wins):

```yaml
- id: dsh-web-search-plugin
  config:
    provider: searxng
    searxngBaseURL: http://127.0.0.1:8888
```

| `provider` | Key needed | Queries go to |
|---|---|---|
| `tavily` *(default here)* | none — the plugin sends `x-tavily-access-mode: keyless` | Tavily, US |
| `searxng` | none | your own instance, or a public one |
| `exa` | `exaApiKey` or `$EXA_API_KEY` | Exa, US |
| `brave` | `braveApiKey` or `$BRAVE_API_KEY` | Brave, US |
| `serper`, `serpapi`, `scavio`, `firecrawl` | respective key | respective vendor |

`scripts/setup-searxng.ps1` runs a local SearXNG bound to `127.0.0.1` only, with
`search.formats` set to include `json` — which SearXNG's shipped `settings.yml`
leaves off, and which the plugin's SearXNG backend needs.

The script preserves an existing generated secret, creates new secrets with a
cryptographically secure random generator, refuses to overwrite unrelated
settings unless `-ForceConfig` is supplied, checks every Docker exit code, and
records the resolved image id. On restart it reuses a locked image or the active
container's immutable image id. Pass `-Image` with an audited digest or
versioned tag for a fresh installation instead of relying on mutable `latest`.

## Uninstall

```powershell
dsh plugin --profile web remove dsh-egress-guard
pwsh -File scripts\block-deepseek-hosts.ps1 -Remove
```

## Scope and caveats

The DSH profile and the external search dependency are both version-sensitive.
Run the verifier before and after an upgrade.

- **Originally audited against `@deepseek-ai/dsh-base` / `dsh-web-app`
  0.2.1-alpha.3 and revalidated as an effective profile on 0.2.3-alpha.2.**
  A release that removes or renames a targeted row may change the protection
  boundary even when startup still succeeds.
- **Audited and pinned to `dsh-web-search-plugin` 0.5.1** (MIT, not part of
  DSH). The exact version prevents a later profile install from silently
  resolving a different, unaudited implementation:

  ```powershell
  # what is actually installed, and is it still the audited version?
  (Get-Content $env:DSH_HOME\profiles\web\node_modules\dsh-web-search-plugin\package.json -Raw | ConvertFrom-Json).version
  ```

  The audit covered: its only network targets are the eight documented search
  backends, it contains no `eval`, `new Function`, `child_process`, or base64
  decoding, its `usage.js` writes only a local file under `$DSH_HOME/storages`,
  and its browser bundle's only `fetch` is a relative path on its own host. It
  does hold your API keys and has full network access, so a version other than
  `0.5.1` is not the pinned/audited version.

  The backend is chosen by this bundle's `provider: tavily` patch or by the
  profile's later override, not by the plugin's own default. The exact
  dependency plus the effective-profile verifier makes an accidental change
  observable.
- **The profile's own `cordis.patch.yml` wins** over this bundle's layer, so any
  single row here can be overridden without touching the package.
- **Uploads that already happened are not recalled** by installing this, and a
  session-log upload watermark already accepted by the server is not revoked.
- **DeepSeek model weights served by another vendor do not mean no third party
  receives the prompt.** Unmounting the DeepSeek routes closes the audited path
  to DeepSeek itself; the substitute vendor becomes the receiving party and must
  meet the retention, training, region, subprocessor, and lawful-access
  requirements for the deployment. A provider name or "open weights" label is
  not a substitute for that review.

## License

MIT.
