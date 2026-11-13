# Tally

A native iPhone dashboard for your bank balances, transactions, spending, payment history, and an optional financial chat assistant. A Cloudflare Worker syncs your own Plaid connections into D1; the app and its widget read that saved data.

Tally is free and open source. It is designed for **one owner per backend deployment**. Run your own backend and use your own credentials; this repository does not provide access to the author's financial service. Plaid, AI, and hosting services have separate terms, quotas, and possible charges.

## Features

- Checking and credit-account balances, transactions, spending, and balance history.
- Bank linking and reconnection through Plaid Hosted Link.
- Scheduled bank refreshes with durable retry jobs.
- A widget with a separate read-only access token.
- Optional Ask Tally chat using your own OpenAI API key.
- Optional device authentication and a debug-only sample-data mode.

## Requirements

- A Mac with Xcode and an iOS 18 or newer SDK; a compatible iPhone for device testing.
- A current Node.js release with built-in TypeScript support and `node:sqlite` for backend tests (Node 22.13 or newer).
- A Cloudflare account with Workers and D1, and your own Plaid application.

The public configuration defaults to Plaid **sandbox** with paid transaction-refresh requests disabled. Use sandbox while evaluating the project. Real bank connections require your own Plaid production access and appropriate provider setup.

## Backend setup

```sh
git clone https://github.com/ppratick/Tally.git
cd Tally/Backend
npm ci
npx wrangler login
cp wrangler.jsonc wrangler.local.jsonc
npx wrangler d1 create tally
```

In the ignored `wrangler.local.jsonc`, set a unique Worker name, your D1 database name/ID, and `PUBLIC_URL` to your own Worker URL. Add `account_id` if your login can access multiple accounts.

Initialize the new database:

```sh
npx wrangler d1 execute DB --remote --file=schema.sql -c wrangler.local.jsonc
```

Set these production secrets using `npx wrangler secret put NAME -c wrangler.local.jsonc`:

| Secret | Purpose |
|---|---|
| `APP_TOKEN` | App access; generate with `openssl rand -hex 32`. |
| `WIDGET_TOKEN` | Widget-only access; generate a different random token. |
| `TOKEN_ENCRYPTION_KEY` | Stored bank credentials; generate with `openssl rand -base64 32`. Keep this key for existing data. |
| `PLAID_CLIENT_ID` | Your Plaid client ID. |
| `PLAID_SECRET` | The secret for the Plaid environment selected in your local config. |

Leave `PLAID_ITEMS` unset for a new deployment. Connect banks through the app instead of embedding bank access tokens in source files.

```sh
npm run deploy
```

The Worker exposes `/health`; private routes require an access token. Plaid webhooks use `/webhooks/plaid` and signature verification. Keep `PUBLIC_URL` correct when changing the deployment address.

For local development, copy `.dev.vars.example` to `.dev.vars`, fill in development-only values, initialize a local database with `npx wrangler d1 execute DB --local --file=schema.sql`, and run `npm run dev`. The iPhone connection screen requires HTTPS; use the deployed Worker for a physical-device connection.

## iPhone app

Open `Tally.xcodeproj` from the repository root. Select the **Tally** scheme and your simulator or iPhone. For your own device, select your own signing team and unique bundle identifiers for the app and widget. Keep the shared Keychain group consistent between both targets. If regenerating with XcodeGen, make those choices in `project.yml` first.

On first launch, enter **your Worker URL** and **your APP_TOKEN**. Connect your bank through the app. The app obtains the separate widget token from the authenticated backend. Connection details and your optional OpenAI key are stored in the device Keychain.

To try the interface without a backend, use a Debug build in the Simulator and add `-TallyDemo` under the scheme's launch arguments. Sample mode does not contact the backend.

A free Apple Personal Team can install a development build on your own iPhone, subject to Apple's capability restrictions and seven-day provisioning expiry. This is a source build; no App Store release or installer is provided.

## Optional AI

Add your own OpenAI API key in **Settings → Ask Tally**. It is stored in Keychain and sent to your own backend for each chat request. Relevant financial records are sent to OpenAI when answering a question. AI use may incur API charges; the app works as a financial dashboard without it.

## Tests

```sh
cd Backend
npm run check
npm test
```

Backend tests use generated credentials, isolated databases, and mocked providers. They cover authorization, webhook verification, retries, financial calculations, chat data boundaries, and redirect handling.

## Keeping your data private

Keep `wrangler.local.jsonc`, `.dev.vars`, pairing files, database exports, financial caches, and real credentials out of Git and shared archives. Generate separate tokens for the app and widget. A deployment serves one owner's data; do not share its access tokens with other users.

## License

Original project code is available under the [MIT license](LICENSE). Third-party bank names and logos belong to their respective owners; their inclusion does not imply endorsement or grant rights to their trademarks.
