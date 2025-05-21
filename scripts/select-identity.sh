#!/bin/bash

IFS=$'\n' names=($(security find-identity -vp codesigning | grep -E '(?:iPhone Developer|Apple Development):' | cut -d'"' -f2 | uniq))
if [[ "${#names[@]}" -eq 1 ]]; then
	identity="${names[0]}"
else
	echo "Select identity" >&2
	for i in "${!names[@]}"; do 
	  	printf "%s. %s\n" $((i + 1)) "${names[$i]}" >&2
	done
	# ask for choice until the user supplies a valid answer
	function select_identity {
		read -p "Choice (enter number): " identity_idx >&2
		if [[ "$identity_idx" -lt 1 || "$identity_idx" -gt "${#names[@]}" ]]; then
			select_identity
		else
			identity="${names[$((identity_idx - 1))]}"
		fi
	}
	select_identity
fi

# we can't simply extract the portion in brackets because some times the Organizational Unit is different from that
# so extract that info from the certificate
team=$(security find-certificate -pc "$identity" | openssl x509 -noout -subject | grep -o 'OU=[A-Z0-9]*' | cut -d= -f2)

echo -n "$team"
