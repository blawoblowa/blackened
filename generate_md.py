#!/usr/bin/env python3
import json
import os
import sys
import time
import urllib.parse
import urllib.request
from collections import Counter

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
LIST_IP_PATH = os.path.join(SCRIPT_DIR, "ip_list.csv")
LIST_MD_PATH = os.path.join(SCRIPT_DIR, "ip_list.md")
CACHE_FILE = os.path.join(SCRIPT_DIR, ".ip_cache.json")
ENV_FILE = os.path.join(SCRIPT_DIR, ".env")

def load_env():
    """Membaca file .env jika tersedia."""
    env_vars = {}
    if os.path.exists(ENV_FILE):
        try:
            with open(ENV_FILE, "r") as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith("#") and "=" in line:
                        k, v = line.split("=", 1)
                        env_vars[k.strip()] = v.strip().strip('"').strip("'")
        except Exception as e:
            print(f"Warning: Gagal membaca .env: {e}", file=sys.stderr)
    return env_vars

def get_abuseipdb_api_key():
    env_vars = load_env()
    return os.environ.get("ABUSEIPDB_API_KEY") or env_vars.get("ABUSEIPDB_API_KEY", "")

def load_cache():
    if os.path.exists(CACHE_FILE):
        try:
            with open(CACHE_FILE, "r") as f:
                return json.load(f)
        except Exception:
            return {}
    return {}

def save_cache(cache):
    try:
        with open(CACHE_FILE, "w") as f:
            json.dump(cache, f, indent=2)
    except Exception as e:
        print(f"Warning: Gagal menyimpan cache: {e}", file=sys.stderr)

def fetch_ip_info_batch(ips_to_fetch):
    """Mengambil metadata geolokasi & ISP secara batch (50 IP per request)."""
    batch_size = 50
    results = {}
    
    for i in range(0, len(ips_to_fetch), batch_size):
        chunk = ips_to_fetch[i:i + batch_size]
        payload = [
            {
                "query": ip,
                "fields": "status,message,country,countryCode,regionName,city,isp,org,as,mobile,proxy,hosting,query"
            }
            for ip in chunk
        ]
        data = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(
            "http://ip-api.com/batch",
            data=data,
            headers={"Content-Type": "application/json"}
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                batch_res = json.loads(resp.read().decode("utf-8"))
                for item in batch_res:
                    q = item.get("query")
                    if q:
                        results[q] = item
        except Exception as e:
            print(f"Warning: Gagal mengambil data batch IP ({e})", file=sys.stderr)
        
        if i + batch_size < len(ips_to_fetch):
            time.sleep(0.5)
            
    return results

def fetch_abuseipdb_info(ip, api_key):
    """Mengambil data reputasi & riwayat serangan dari AbuseIPDB."""
    url = f"https://api.abuseipdb.com/api/v2/check?ipAddress={urllib.parse.quote(ip)}&maxAgeInDays=90"
    req = urllib.request.Request(
        url,
        headers={
            "Key": api_key,
            "Accept": "application/json",
            "User-Agent": "Blackened-ThreatIntel/1.0"
        }
    )
    try:
        with urllib.request.urlopen(req, timeout=8) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            return data.get("data", {})
    except Exception as e:
        print(f"Warning: Gagal fetch AbuseIPDB untuk {ip}: {e}", file=sys.stderr)
        return None

def main():
    if not os.path.exists(LIST_IP_PATH):
        print(f"File {LIST_IP_PATH} tidak ditemukan.")
        return

    with open(LIST_IP_PATH, "r") as f:
        ips = [line.strip() for line in f if line.strip()]

    if not ips:
        print("ip_list.csv kosong. Tidak ada data untuk digenerate.")
        return

    cache = load_cache()
    api_key = get_abuseipdb_api_key()

    # 1. Cek IP yang belum ada data GeoIP di cache
    missing_geo_ips = [ip for ip in ips if ip not in cache or cache[ip].get("status") != "success"]
    if missing_geo_ips:
        print(f"Mengambil metadata Geo/ISP untuk {len(missing_geo_ips)} IP baru...")
        new_geo_data = fetch_ip_info_batch(missing_geo_ips)
        for ip, gdata in new_geo_data.items():
            if ip in cache:
                cache[ip].update(gdata)
            else:
                cache[ip] = gdata
        save_cache(cache)

    # 2. Cek IP yang belum ada data AbuseIPDB di cache (jika API Key tersedia)
    if api_key:
        missing_abuse_ips = [ip for ip in ips if "abuse_data" not in cache.get(ip, {})]
        if missing_abuse_ips:
            print(f"Mengambil data AbuseIPDB untuk {len(missing_abuse_ips)} IP...")
            for idx, ip in enumerate(missing_abuse_ips, 1):
                abuse_res = fetch_abuseipdb_info(ip, api_key)
                if abuse_res:
                    if ip not in cache:
                        cache[ip] = {}
                    cache[ip]["abuse_data"] = {
                        "abuseConfidenceScore": abuse_res.get("abuseConfidenceScore", 0),
                        "totalReports": abuse_res.get("totalReports", 0),
                        "lastReportedAt": abuse_res.get("lastReportedAt"),
                        "usageType": abuse_res.get("usageType")
                    }
                else:
                    if ip in cache:
                        cache[ip]["abuse_data"] = None
                
                # Jaga jeda request
                if idx < len(missing_abuse_ips):
                    time.sleep(0.3)
            save_cache(cache)

    total_ips = len(ips)
    valid_records = [cache.get(ip, {}) for ip in ips if cache.get(ip, {}).get("status") == "success"]

    def get_type(d):
        if d.get("hosting"):
            return "Data Center / Hosting"
        elif d.get("mobile"):
            return "Mobile / Cellular"
        return "Residential / ISP"

    types = Counter([get_type(d) for d in valid_records])
    countries = Counter([d.get("country", "Unknown") for d in valid_records])
    isps = Counter([d.get("isp", "Unknown") for d in valid_records])

    # Hitung statistik Abuse
    has_abuse_info = any("abuse_data" in cache.get(ip, {}) and cache[ip]["abuse_data"] for ip in ips)
    high_threat = 0
    medium_threat = 0
    low_threat = 0

    if has_abuse_info:
        for ip in ips:
            adata = cache.get(ip, {}).get("abuse_data")
            if adata:
                score = adata.get("abuseConfidenceScore", 0)
                if score >= 50:
                    high_threat += 1
                elif score > 0:
                    medium_threat += 1
                else:
                    low_threat += 1

    lines = []
    lines.append("# Detail Intelijen IP Address (`ip_list.md`)")
    lines.append("")
    lines.append(f"Dokumen ini berisi informasi detail geografis, ISP, tipe infrastruktur, ASN, dan reputasi AbuseIPDB untuk seluruh **{total_ips} IP** yang terdaftar di [`ip_list.csv`](file://{LIST_IP_PATH}).")
    lines.append("")
    lines.append("---")
    lines.append("")
    lines.append("## Ringkasan Statistik")
    lines.append("")
    
    if has_abuse_info:
        lines.append("### 1. Tingkat Ancaman (AbuseIPDB Threat Level)")
        lines.append("| Kategori Ancaman | Skor Abuse | Jumlah IP | Keterangan |")
        lines.append("| :--- | :--- | :--- | :--- |")
        lines.append(f"| **Tinggi (High Risk)** | >= 50% | {high_threat} | Sangat berbahaya / aktif dilaporkan menyerang |")
        lines.append(f"| **Sedang (Suspicious)** | 1% - 49% | {medium_threat} | Terindikasi aktivitas mencurigakan |")
        lines.append(f"| **Bersih / Rendah (Clean)** | 0% | {low_threat} | Belum ada laporan serangan aktif |")
        lines.append("")

    sec_idx = 2 if has_abuse_info else 1
    lines.append(f"### {sec_idx}. Distribusi Tipe Infrastruktur")
    lines.append("| Tipe | Jumlah | Persentase |")
    lines.append("| :--- | :--- | :--- |")
    for t, count in types.most_common():
        pct = (count / total_ips) * 100 if total_ips > 0 else 0
        lines.append(f"| **{t}** | {count} | {pct:.1f}% |")

    lines.append("")
    sec_idx += 1
    lines.append(f"### {sec_idx}. Top 5 Negara Asal")
    lines.append("| Negara | Jumlah IP |")
    lines.append("| :--- | :--- |")
    for c, count in countries.most_common(5):
        lines.append(f"| {c} | {count} |")

    lines.append("")
    sec_idx += 1
    lines.append(f"### {sec_idx}. Top 5 ISP / Cloud Provider")
    lines.append("| ISP / Organisasi | Jumlah IP |")
    lines.append("| :--- | :--- |")
    for isp, count in isps.most_common(5):
        lines.append(f"| {isp} | {count} |")

    lines.append("")
    lines.append("---")
    lines.append("")
    lines.append("## Tabel Detail IP Address")
    lines.append("")
    
    if has_abuse_info:
        lines.append("| No | IP Address | Abuse Score | Total Laporan | Tipe | ISP / Provider | Organisasi / Cloud | Negara | Provinsi | Kota | ASN | Proxy/VPN |")
        lines.append("| :-: | :--- | :-: | :-: | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :-: |")
    else:
        lines.append("| No | IP Address | Tipe | ISP / Provider | Organisasi / Cloud | Negara | Provinsi / Region | Kota | ASN | Proxy/VPN |")
        lines.append("| :-: | :--- | :-: | :-: | :--- | :--- | :--- | :--- | :--- | :--- | :-: |")

    for idx, ip in enumerate(ips, 1):
        d = cache.get(ip, {})
        if d.get("status") != "success":
            if has_abuse_info:
                lines.append(f"| {idx} | `{ip}` | - | - | Unknown | Unknown | Unknown | Unknown | Unknown | Unknown | Unknown | - |")
            else:
                lines.append(f"| {idx} | `{ip}` | Unknown | Unknown | Unknown | Unknown | Unknown | Unknown | Unknown | - |")
            continue

        tipe = get_type(d)
        isp = d.get("isp", "-").replace("|", "/")
        org = (d.get("org") or "-").replace("|", "/")
        country = d.get("country", "-")
        region = d.get("regionName", "-")
        city = d.get("city", "-")
        asn = d.get("as", "-").replace("|", "/")
        proxy = "Ya" if d.get("proxy") else "Tidak"

        if has_abuse_info:
            adata = d.get("abuse_data")
            if adata:
                score = adata.get("abuseConfidenceScore", 0)
                reports = adata.get("totalReports", 0)
                badge = f"{score}%"
                reports_str = f"{reports:,}"
            else:
                badge = "-"
                reports_str = "-"
            lines.append(f"| {idx} | `{ip}` | {badge} | {reports_str} | {tipe} | {isp} | {org} | {country} | {region} | {city} | {asn} | {proxy} |")
        else:
            lines.append(f"| {idx} | `{ip}` | {tipe} | {isp} | {org} | {country} | {region} | {city} | {asn} | {proxy} |")

    with open(LIST_MD_PATH, "w") as f:
        f.write("\n".join(lines) + "\n")

    print(f"Berhasil memperbarui {LIST_MD_PATH} (Total: {total_ips} IP)")

if __name__ == "__main__":
    main()
