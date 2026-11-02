##! Orion-X site policy for the live sensor (orionx-zeek@.service).
##!
##! @decision DEC-PHASE13-033
##! @title The deck's Zeek loads a curated policy, not the stock `local`,
##!   and rotates hourly into a bounded archive
##! @status accepted
##! @rationale The stock site/local.zeek loads two scripts that make a passive
##!   sensor phone out per observation: frameworks/files/detect-MHR queries
##!   Team Cymru's Malware Hash Registry over DNS for every file hash seen, and
##!   policy/frameworks/notice/extend-email/hostnames does a reverse DNS lookup
##!   for every notice. protocols/ssh/geo-data wants a GeoIP database the image
##!   does not ship and warns on every run. The deck promises no unprompted
##!   outbound traffic (User Guide §Network), so those three are left out and
##!   the unit's RestrictAddressFamilies makes the omission enforceable rather
##!   than conventional. Everything else from `local` that produces the logs
##!   orionx-postured and orionx-logquery consume (conn, notice, weird, dns,
##!   http, ssl, ssh, files, software, known-*) is kept.
##!
##!   Rotation: Log::default_rotation_interval is 0 (never) when Zeek runs
##!   without zeekctl, and the live overlay is RAM. One hour, into ./archive
##!   under the instance's /var/log/zeek/<iface>/, with orionx-zeek-prune as
##!   the postprocessor keeping the archive under its byte and age caps. The
##!   live files keep their plain names (conn.log, notice.log, ...) so the
##!   ingest tailers reattach by inode after each rotation (LogTailer).

# ---- analysis (the subset of site/local.zeek that stays on the wire) -------
@load misc/capture-loss
@load misc/stats
@load frameworks/software/vulnerable
@load frameworks/software/version-changes
@load-sigs frameworks/signatures/detect-windows-shells
@load protocols/ftp/software
@load protocols/smtp/software
@load protocols/ssh/software
@load protocols/http/software
@load protocols/dns/detect-external-names
@load protocols/ftp/detect
@load protocols/conn/known-hosts
@load protocols/conn/known-services
@load protocols/ssl/known-certs
@load protocols/ssl/validate-certs
@load protocols/ssl/log-hostcerts-only
@load protocols/ssh/detect-bruteforcing
@load protocols/ssh/interesting-hostnames
@load protocols/http/detect-sql-injection
@load frameworks/files/hash-all-files

# NOT loaded, on purpose (see @rationale):
#   frameworks/files/detect-MHR                      — DNS to Team Cymru per hash
#   policy/frameworks/notice/extend-email/hostnames  — reverse DNS per notice
#   protocols/ssh/geo-data                           — needs a GeoIP DB the image lacks

# ---- log rotation: hourly, into a bounded archive --------------------------
redef Log::default_rotation_interval = 1hr;
redef Log::default_rotation_dir = "archive";
redef Log::default_rotation_postprocessor_cmd = "/opt/orionx/scripts/awareness/orionx-zeek-prune";

# TSV, not JSON: orionx-postured reads both, orionx-logquery and zeek-cut
# expect the #fields header (DEC-PHASE12-028).
redef LogAscii::use_json = F;
