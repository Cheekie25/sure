# DeFi positions providers (CoinStats / Zerion)

Wallets linked through a CoinStats connection can have their DeFi and staking
positions (Lido stETH, Aave deposits, liquidity pools...) refreshed by one of
two providers:

| Provider  | Default | What it refreshes | Credentials |
|-----------|---------|-------------------|-------------|
| CoinStats | yes     | `/wallet/defi` per wallet and blockchain | the CoinStats connection's API key |
| Zerion    | no      | `GET /v1/wallets/{address}/positions/?filter[positions]=only_complex` | `ZERION_API_KEY` or the Self-Hosting setting |

Only DeFi positions change provider. Wallet token balances, exchange portfolios
and transactions always come from CoinStats.

## How it works

```
CoinstatsItem::Importer
  -> CoinstatsItem::DefiSource.build          picks CoinStats or Zerion
       -> DefiSource::Coinstats | DefiSource::Zerion
            -> Provider::Coinstats | Provider::Zerion   HTTP only
            <- CoinstatsItem::DefiPosition              normalized positions
  -> CoinstatsItem::DefiAccountManager        creates / updates / zeroes accounts
CoinstatsItem::Syncer                         reports partial failures in sync stats
```

`CoinstatsItem::DefiPosition` carries explicit monetary fields:
`value_usd` is the total value of the position, `unit_price_usd` is the price
of one token. (CoinStats returns the total value in a field named `price`;
Zerion returns the total in `value` and the unit price in `price`.)

Safety rules enforced by the code:

- A provider error (401, 429, 5xx, timeout) or an invalid response is never
  treated as an empty wallet. Existing balances are kept untouched.
- Positions that disappeared are zeroed (never deleted) only after a complete,
  valid response, and only if every position of that response was saved.
- Zero-out is scoped to the provider that produced the response. Switching
  provider never zeroes the accounts created by the other provider.
- There is no automatic fallback between providers.
- A sync whose DeFi refresh failed still completes, but the sync summary lists
  the error and the CoinStats card shows "Last sync completed with errors".
  Failures are also recorded in `/settings/debug` (`provider_sync_error`).
- Zerion `loan` legs, spam (`is_trash`) and non-displayable share tokens are
  not imported; skipped loans are listed in the sync summary.

## Configuration

1. Create a key on the [Zerion dashboard](https://dashboard.zerion.io).
2. Store it either:
   - in **Settings > Self-Hosting > DeFi Positions Provider > Zerion API key**
     (stored encrypted, like the other provider keys), or
   - as the `ZERION_API_KEY` environment variable (takes precedence).
3. Validate before switching (read-only, writes nothing to the database):

   ```bash
   bin/rails "coinstats_defi:compare[0xYourAddress,ethereum]"
   bin/rails "coinstats_defi:fetch[zerion,0xYourAddress,ethereum]"
   ```

   Each run consumes one Zerion request and CoinStats credits.

On Docker Compose, run the task inside the web container, e.g.
`docker compose exec web bin/rails "coinstats_defi:compare[0x...,ethereum]"`.

## Activation

Select **Zerion** in **Settings > Self-Hosting > DeFi Positions Provider**, or
set `COINSTATS_DEFI_PROVIDER=zerion` (takes precedence over the setting).
Then trigger a sync of the CoinStats connection.

The first Zerion sync creates new DeFi accounts (ids prefixed `defi:zerion:`).
DeFi accounts previously created by CoinStats are kept with their last balance
and are no longer refreshed; the sync summary counts them. Hide or delete them
manually once you have checked the Zerion accounts, otherwise the same
position is counted twice in net worth.

## Rollback to CoinStats

Select **CoinStats (default)** again (or remove `COINSTATS_DEFI_PROVIDER`).
CoinStats DeFi accounts resume refreshing with their original ids; Zerion
accounts are kept, frozen at their last value, and can be hidden. No data is
deleted in either direction.

## Quota

- Zerion counts `only_complex` requests in an "advanced" sub-quota equal to
  25% of the plan quota (the free Developer plan lists 2,000 requests/day and
  3 requests/second).
- One request per wallet address and sync, whatever the number of linked
  chains (the endpoint returns every chain at once and is not paginated).
- Successful responses are cached for 10 minutes
  (`ZERION_DEFI_CACHE_TTL_SECONDS`, `0` disables the cache), so repeated
  manual syncs do not consume extra requests.
- Example: 1 address synced hourly = 24 requests/day, about 720/month.
- Optional local budget: `ZERION_DAILY_REQUEST_LIMIT=250` stops Zerion calls
  for the rest of the UTC day once 250 HTTP attempts (retries included) were
  made, keeping headroom below a 300 requests/day key. The counter lives in
  the Rails cache (Redis in the Docker setup), so web and worker share it.
  When Zerion answers 429 with an exhausted daily quota, further calls are
  skipped until the next UTC day. In both cases existing positions are kept
  and the sync summary shows the error.
- Retries: 429, 500, 502, 503, 504 and network errors are retried up to 3
  times with exponential backoff (honoring `Retry-After` /
  `RateLimit-Org-Second-Reset`). A 429 with an exhausted daily or monthly
  quota is not retried. 400 and 401 are never retried.

Supported Zerion chains for DeFi positions are listed in
`CoinstatsItem::DefiSource::Zerion::SUPPORTED_CHAINS`; other blockchains are
reported as unsupported and left untouched.
