import urllib.request
import maxminddb
import os
import sys
import argparse


DB_URL = "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/GeoLite2-ASN.mmdb"
_DEFAULT_DB_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "GeoLite2-ASN.mmdb")


# ─── Configure ASNs to extract ───────────────────────────────────────────────
TARGET_ASNS = {
    132203, # Tencent
    139341, # WeChat QQ CDN
    136907, # Huawei
    45102,  # Aliyun
    24429,  # Aliyun
    134963, # Aliyun
    25820,  # IT7
}
# ─────────────────────────────────────────────────────────────────────────────


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--refresh", action="store_true")
    parser.add_argument("--db-path", default=_DEFAULT_DB_PATH)
    args = parser.parse_args()

    db_path = args.db_path

    if not os.path.exists(db_path) or args.refresh:
        print("Downloading ASN database...", file=sys.stderr)
        urllib.request.urlretrieve(DB_URL, db_path)
        print("Download complete.", file=sys.stderr)

    print(f"Extracting CIDRs for ASNs: {TARGET_ASNS} ...", file=sys.stderr)

    results = []
    append = results.append  # avoid repeated attribute lookup in hot loop
    target = TARGET_ASNS     # local binding is faster than global lookup

    with maxminddb.open_database(db_path, maxminddb.MODE_MMAP) as reader:
        for network, data in reader:
            if data and data["autonomous_system_number"] in target:
                prefix = "IP-CIDR6" if network.version == 6 else "IP-CIDR"
                append(f"{prefix},{network}")

    sys.stdout.write("\n".join(sorted(results)))
    if results:
        sys.stdout.write("\n")

    print(f"Total: {len(results)} prefixes.", file=sys.stderr)


if __name__ == "__main__":
    main()