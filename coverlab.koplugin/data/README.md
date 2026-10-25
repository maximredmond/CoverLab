# HTTPS trust store

`ca-bundle.crt` is the Mozilla CA certificate bundle distributed by the curl project, downloaded from <https://curl.se/ca/cacert.pem>. Its header records the extraction date and source. Update it from that HTTPS source when preparing releases; do not disable certificate verification to work around expired or missing roots.

Certificate source and licensing information: <https://curl.se/docs/caextract.html> and <https://www.mozilla.org/en-US/MPL/2.0/>.
