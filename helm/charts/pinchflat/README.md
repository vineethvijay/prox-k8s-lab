# Pinchflat

YouTube channel downloader with optional Gluetun VPN sidecar.

## Source Channel

- **FITZONE** (`UCaNvcPv1KNQtGBI5iTRCwqg`) — daily gym/workout music mixes

## yt-dlp Settings

Configured via ConfigMap → `/config/extras/yt-dlp-configs/base-config.txt`:

| Setting | Value |
|---|---|
| Format | `bv*[height<=1080][fps<=60]+ba/b` |
| Format sort | `vcodec:h264,res:1080,acodec:aac` |
| Output | MP4 |
| Metadata | `--write-info-json`, `--write-description`, `--write-thumbnail` |
| Download archive | `/downloads/download_archive.txt` |

**Result:** h264 1080p/60fps video + AAC audio in MP4 container (matches old TubeArchivist settings).

## Storage

- **Config PVC:** `nfs-hdd` (1Gi) — Pinchflat SQLite DB + yt-dlp configs
- **Downloads:** hostPath `/mnt/nfs/hdd-int/tube-archiver` (same path as old TubeArchivist)
- **Download archive:** 336 entries migrated from TubeArchivist + new entries appended by Pinchflat

## VPN

Toggle via `values.yaml`:

```yaml
vpn:
  enabled: false  # set to true to enable Gluetun WireGuard sidecar
```

## Migration from TubeArchivist

- 336 video IDs exported from TA Elasticsearch into `download_archive.txt`
- Cutoff date set to `2026-04-05` in Pinchflat UI to skip old videos
- Old TA videos remain at `/downloads/UCaNvcPv1KNQtGBI5iTRCwqg/*.mp4`
- New Pinchflat videos go to `/downloads/FITZONE/<date> <title>/<title> [<id>].mp4`
