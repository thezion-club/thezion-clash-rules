import urllib.request
import maxminddb
import os
import sys
import argparse


DB_URL = "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/GeoLite2-ASN.mmdb"
_DEFAULT_DB_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "GeoLite2-ASN.mmdb")


# ─── Configure ASNs to extract ───────────────────────────────────────────────
TARGET_ASNS = {
    132203,
    55990,
    45102,
    25820,
}
# ─────────────────────────────────────────────────────────────────────────────


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--refresh", action="store_true", help="Force re-download of the DB")
    parser.add_argument("--db-path", default=_DEFAULT_DB_PATH, help="Path to store/read GeoLite2-ASN.mmdb")
    args = parser.parse_args()

    db_path = args.db_path

    if not os.path.exists(db_path) or args.refresh:
        print("Downloading ASN database...", file=sys.stderr)
        urllib.request.urlretrieve(DB_URL, db_path)
        print("Download complete.", file=sys.stderr)

    print(f"Extracting CIDRs for ASNs: {TARGET_ASNS} ...", file=sys.stderr)
    results = []
    with maxminddb.open_database(db_path, maxminddb.MODE_MMAP) as reader:
        for network, data in reader:
            if data and data.get("autonomous_system_number") in TARGET_ASNS:
                results.append(str(network))

    for cidr in sorted(results):
        print(cidr)  # stdout only — consumed by caller

    print(f"Total: {len(results)} prefixes.", file=sys.stderr)


if __name__ == "__main__":
    main()