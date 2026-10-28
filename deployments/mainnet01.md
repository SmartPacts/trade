# Mainnet deployment — mainnet01, all 20 chains

`n_48867b242317a0216a67f8c7ca26696b5878e0e3.trade`, deployed by one transaction per chain. Each
transaction's code was the whole of `pact/modules/trade.pact` (the namespace line, the governance
keyset rule, the module and the table-creating footer). Every row below was read back from
`api.chainweb-community.org` with `/poll` (read-only) on 2026-10-28: status, gas, block height and
block time are the chain's own answer. A request key is the transaction's hash.

Check any row yourself (replace the chain and the key):

```bash
curl -s -X POST -H 'content-type: application/json' \
  -d '{"requestKeys":["RmAuvuTcP4W-ji-zRZWJmv98vkUsd2NDM698H-kbByk"]}' \
  https://api.chainweb-community.org/chainweb/0.0/mainnet01/chain/2/pact/api/v1/poll
```

Module hash on every chain: `2CpBKDy_mx5Oc1RiFI5fwv6c-UsKJ9KUzxj3nqSzB0o`. That the code each chain
runs is this repository's file, character for character, is checked by
`python3 .github/scripts/verify-onchain.py` (README).

| chain | request key | status | gas | block height | block time (UTC) |
|---:|---|---|---:|---:|---|
| 0 | `jsG2mE1JWyG5KfYEjbqkfl19XglgNJXuVIitnXegTOE` | success | 35,579 | 7,353,884 | 2026-10-28 03:46:46 |
| 1 | `8DopwQEQ5hAw7CChkIZTIlHi6Hb5OcORhFcnNnCIlJ8` | success | 35,579 | 7,353,885 | 2026-10-28 03:47:23 |
| 2 | `RmAuvuTcP4W-ji-zRZWJmv98vkUsd2NDM698H-kbByk` | success | 35,579 | 7,353,886 | 2026-10-28 03:47:58 |
| 3 | `vwbvAoCtItbk1i_B1pMr2GI68T4iWbNtR-frs9V8_F8` | success | 35,579 | 7,353,888 | 2026-10-28 03:49:03 |
| 4 | `48zMH3sU6zHN-8iV1abb61nNA1vxiBsNtGSw4i17Uww` | success | 35,579 | 7,353,891 | 2026-10-28 03:50:00 |
| 5 | `udO_MSA8h3MM_oinwmTXLb6CuiOqJB6lYh7D91byyBc` | success | 35,579 | 7,353,893 | 2026-10-28 03:50:47 |
| 6 | `Doqj-XQJRJ2gMQMPByAbcDwJsds6igqEauw7JpjLIwQ` | success | 35,579 | 7,353,894 | 2026-10-28 03:51:18 |
| 7 | `RAZ2K5pd_OYd1qt1BkfPNJv39zLM1fySV6IKOPyefr4` | success | 35,579 | 7,353,896 | 2026-10-28 03:52:08 |
| 8 | `uN_0edHkZOdRvhC5o6x5LOU7t9Z5RkrHGZpSk7_L6jg` | success | 35,579 | 7,353,896 | 2026-10-28 03:52:38 |
| 9 | `-8iQJHtk22_acZ7hJtBCKcBMt8zPvOUgSt9gXul-_3A` | success | 35,579 | 7,353,898 | 2026-10-28 03:53:00 |
| 10 | `U3Ny4mr9ZhfS8b31aPMj2B50twO1ZtQYTrO_3kwAMzU` | success | 35,579 | 7,353,899 | 2026-10-28 03:53:32 |
| 11 | `DNiURM7SrU_J6RIL_WCM-I5Htq6klzP5JOapLKZaxP4` | success | 35,579 | 7,353,900 | 2026-10-28 03:54:06 |
| 12 | `owSwycPxUBco6AdpY893LvzF0u2arIx0NtOSqSpJVcY` | success | 35,579 | 7,353,902 | 2026-10-28 03:54:56 |
| 13 | `SsNkiWWGaI43CIQbBnb90gd44rz4-yQVXpmEGSYYAyk` | success | 35,579 | 7,353,904 | 2026-10-28 03:55:31 |
| 14 | `qvr3BX6ZUfxwxXoN6S3KKGzUoaZy7LY6cr4_lcfIsK4` | success | 35,579 | 7,353,905 | 2026-10-28 03:56:31 |
| 15 | `PCxMxjzPwYcw_PHZA5LCT9akx2dDIf5dvbZstQPzEL8` | success | 35,579 | 7,353,907 | 2026-10-28 03:57:12 |
| 16 | `EXEkgpSxgMAYJLoLjFId_gphw6VZx0EjSrVhNniaP6c` | success | 35,579 | 7,353,909 | 2026-10-28 03:58:51 |
| 17 | `Yv5-O50WKNZqlZ42IQlAX9IAVlGG0OYOjJTcGQahKYU` | success | 35,579 | 7,353,910 | 2026-10-28 03:59:23 |
| 18 | `VXwE0VFNM1OXUfXv4oXXRufIZmhbaamJ00UhJ68q5Vs` | success | 35,579 | 7,353,912 | 2026-10-28 03:59:51 |
| 19 | `AmAZvoq5qC-WPIVq2Ck8Uxnd23-ediNnP6Vnp_pS9WY` | success | 35,579 | 7,353,913 | 2026-10-28 04:00:39 |

Each transaction returned `["TableCreated", "TableCreated", "orders and settings tables created"]`:
the two tables were created and the governance keyset `n_48867b242317a0216a67f8c7ca26696b5878e0e3.trade-gov`
(a `keys-2` keyset of three keys) was defined in the same transaction.
