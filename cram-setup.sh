column-header() {
	REPLY=
	while (($#)); do REPLY+=${1: ${#REPLY}}; shift; done
	REPLY=${REPLY//?/-}
}

dump-tables () {
	while (($#)); do
		echo  # blank line before each table
		local -n arr=$1
		column-header "$1" "${!arr[@]}"; local h1=$REPLY fmt="%-${#REPLY}s  %s\n"
		column-header "[]" "${arr[@]}";  local h2=$REPLY
		printf "$fmt" "$1" "[]";
		printf "$fmt" "$h1" "$h2"
		for REPLY in "${!arr[@]}"; do printf "$fmt" "$REPLY" "${arr[$REPLY]}"; done | sort
		shift
	done
}
