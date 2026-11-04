# Sourced by the lab scripts. Loads the site settings from lab.env next to this file (copy lab.env.example).
LAB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[ -r "$LAB/lab.env" ] || { echo "missing $LAB/lab.env: copy lab.env.example and fill it in" >&2; exit 1; }
. "$LAB/lab.env"
# subst <file>: print a template with its @VAR@ placeholders filled in from lab.env
subst() {
  sed -e "s|@RADIUS_SERVER@|$RADIUS_SERVER|g" -e "s|@RADIUS_SECRET@|$RADIUS_SECRET|g" -e "s|@NAS_IP@|$NAS_IP|g" \
      -e "s|@NAS_ID@|$NAS_ID|g" -e "s|@SUB_USER@|$SUB_USER|g" -e "s|@SUB_PASS@|$SUB_PASS|g" "$1"
}
# install_conf <template> <dest>: subst into dest, readable by root only (it holds the RADIUS secret)
install_conf() { install -m 600 /dev/null "$2"; subst "$1" > "$2"; }
# mask: hide the RADIUS secret in logged output
mask() { sed "s|$RADIUS_SECRET|<secret>|g"; }
