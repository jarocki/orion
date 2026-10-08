# Zeek fixtures

`conn.log` and `weird.log` are REAL Zeek output, not hand-written: produced by
`zeek -r` (Zeek 8.1.1) over a synthetic 68-packet capture containing a 60-port
sweep from 10.0.0.9 plus two complete TCP handshakes. Keeping genuine output
here is the point — a hand-typed TSV fixture proves the parser handles what
someone imagined Zeek emits, which is how a format detail (the `#types` line,
the `(empty)` marker, the trailing `#close`) gets missed.

`notice.log` is hand-built in the format Zeek's notice framework writes,
because provoking real notices needs traffic and site policy a build host does
not have. Its header matches the real `#fields`/`#types` shape above.

Regenerate conn/weird with:
    zeek -r <pcap>
