# Optional realm-rank poller

The poller supplies realm-rank and online-player data that the addon cannot fetch itself. It is optional and runs outside the game. The RoR and Idrinth addon packages do not include it.

## Windows

1. Install [Python 3](https://www.python.org/downloads/windows/).
2. Download the [Python poller](https://github.com/jmaartenson/AutoBand/raw/refs/heads/main/optional/autoband_realmrank_poller.py) and [Windows launcher](https://github.com/jmaartenson/AutoBand/raw/refs/heads/main/optional/run_autoband_realmrank_poller_windows.cmd). Save both beside `AutoBand.mod` in `Interface\AddOns\AutoBand`.
3. Run `run_autoband_realmrank_poller_windows.cmd`. It installs `cloudscraper` if needed and updates `AutoBand_RealmRank.csv` every 60 seconds when the online data changes. Leave its console open while playing; Ctrl+C stops it.
4. In AutoBand's Realm tab, enable **Use realm-rank CSV** and click **Refresh now**, or type `/ab csvrefresh`.

## Other setups

Install `cloudscraper` in your Python environment, then run:

```sh
python3 autoband_realmrank_poller.py --poll-seconds 60 --output-csv "/path/to/Interface/AddOns/AutoBand/AutoBand_RealmRank.csv"
```

`--once` fetches one snapshot. `--help` lists options. Keep the output path pointed at the addon folder, even if you store the scripts elsewhere.

The addon treats its packaged placeholder as unavailable data until the poller writes a real snapshot. If the poller stops or the data becomes stale, RR-dependent features become unavailable or use valid cached data. Normal career-rank checks still work.
