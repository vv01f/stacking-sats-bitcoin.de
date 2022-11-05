#!/usr/bin/env sh

### todo
# test for dependencies
# wrap functionality
# nicer output
# add notification
# add installation wrapper for e.g. raspiblitz
# test (un)install and as replacement and in parallel to the kraken stacking-sats script

dependencies="curl jq openssl xxd"
# alt openssl for hmac: `echo "<?= hash_hmac('sha256', $hmac_data, $secret) ?>"|php`
# alt jq: cut, sed, grep
# alt xxd: drop option -binary and use cut, sed or grep to extract the hexcode
colred='\033[0;31m'
colgre='\033[0;32m'
colnon='\033[0m' # No Color

## options
BTCDE_API_KEY=""
BTCDE_API_SECRET=""
BTCDE_API_FIAT="eur"
BTCDE_BUY_AMOUNT=21
BTCDE_BUY_RATIO=0.99
BTCDE_ORDER_TYPE="buy"
BTCDE_MAX_REL_FEE="0.5" # max fee in % that you are willing to pay
BTCDE_WITHDRAW_KEY="" # address to withdraw to
# Optional settings for confirmation mail – requires `blitz.notify.sh on`
# BTCDE_MAIL_SUBJECT="Sats got stacked"
# BTCDE_MAIL_FROM_ADDRESS="humble@satstacker.org"
# BTCDE_MAIL_FROM_NAME="Humble Satstacker"

# Remove this line after verifying everything works
KRAKEN_DRY_RUN_PLACE_NO_ORDER=1 # disable API action for testing
##/options

# sign "${http_method}" "${uri}" "${X_API_KEY}" "${concatted_post_parameters}" "${secret}" "${nonce}"
sign () {
	test $# -ge 5 && {
		http_method="${1}"; shift 
		uri="${1}"; shift 
		export X_API_KEY="${1}"; shift 
		concatted_post_parameters="${1}"; shift 
		secret="${1}"; shift 
		test $# -ge 1 && {
			export X_API_NONCE="${1}"; shift
		} || {
			export X_API_NONCE=$(( $(date +"%s") * 1000 ))
		}
		export X_API_SIGDIGEST="sha256"
		test -z "${http_method}" && concatted_post_parameters=""
		md5=$(echo -n "${concatted_post_parameters}"|md5sum|cut -d " " -f1)
		#~ sleep 1 # to ensure credits
		hmac_data="${http_method}#${uri}#${X_API_KEY}#${X_API_NONCE}#${md5}"
		# hmac_hash
		export X_API_SIGNATURE=$(printf "%s" $(printf "%s" "${hmac_data}" | openssl dgst -${X_API_SIGDIGEST} -hmac "$secret" -binary | xxd -p -c 32))
		printf "%s" "${X_API_SIGNATURE}"
	} || {
		echo "parameters missing. there should be five."
	}
}

# getprice "$tradingpair" "$X_API_KEY" – basic method works without signature
getprice () {
	test ${#} -ge 2 && {
		tradingpair="${1}"; shift
		X_API_KEY="${1}"; shift
		priceurl="https://api.bitcoin.de/v4/${tradingpair}/basic/rate.json?apikey=${X_API_KEY}"
		price=$(curl -s "${priceurl}"|jq -r '.rate .rate_weighted')
		printf "%s" "${price}"
	}
}
# https://stackoverflow.com/questions/806906/how-do-i-test-if-a-variable-is-a-number-in-bash
isnum () { case ${1#[-+]} in ''|.|*[!0-9.]*|*.*.*) return 1;; esac ;}

testpub="401b30e3b8b5d629635a5c613cdb7919" # INVALID PUBKEY, but good for testing
testsec="6fcf9dfbd479ed82697fee719b9f8c610a11ff2a" # INVALID SECKEY, but good for testing
testcmp="da72051ee9348f07fa4b0ed7fe24f88ffc71290a8c96fb453e1804e8f31095b3"
testsig=$(sign "POST" "https://api.bitcoin.de/v4/btceur/orders" "${testpub}" "max_amount_currency_to_trade=0.00486638&min_amount_currency_to_trade=0.00486638&only_kyc_full=0&price=20549.13822522&type=buy" "${testsec}" "1667311312")
test "${testsig}" = "${testcmp}" && echo -e "${colgre}passed${colnon} test:sign." || { echo -e "${colred}failed${colnon} test:sign"; exit 1; }
testpub="" # needs valid pubkey
test ! -z "${testpub}" && {
	testprice=$(getprice "btceur" "${testpub}")
	isnum "${testprice}" && echo -e "${colgre}passed${colnon} test:price." || { echo -e "${colred}failed${colnon} test:price."; exit 1; }
} || {
	echo "missing public key for test:price."
}

exit 0 # block running

api_version=4 # test for api version is missing at the API
X_API_KEY="" # valid public key
secret="" # looks like sha1 – for testing: `shasum <<< "secret"|cut -d " " -f 1` 
tradingpair="btceur" # as documented
priceratio="0.99" # pay other than recent price average 
only_kyc_full=0 # only full kyc, default=0 (no)
spendamount="100" # amount in fiat to spend
MAX_REL_FEE="0.01" # cap relative fee

test -z "${X_API_KEY}" && { echo "API Key missing."; exit 1; }
#~ orderprice=20549.13822522;
tradingprice=$(getprice "${tradingpair}" "${X_API_KEY}")
orderprice=$(LC_NUMERIC=C printf "%1.8f" $(bc <<< "scale=8; ${tradingprice} * ${priceratio}"))
echo "trading price: ${tradingprice}"
echo "order price  : ${orderprice}"
max_amount=$(LC_NUMERIC=C printf "%1.8f" $(bc <<< "scale=8; ${spendamount} / ${orderprice}"))
min_amount=${max_amount} # may be set so something else, if not set defaults to max_amount_currency_to_trade/2
sepa_option=0 # default: 0 (no), 1 is SEPA instant, not plain SEPA

http_method="POST"
uri="https://api.bitcoin.de/v4/${tradingpair}/orders"
# ksort($post_parameters); // parameters must be sorted by key ascending
concatted_post_parameters="max_amount_currency_to_trade=${max_amount}&min_amount_currency_to_trade=${min_amount}&only_kyc_full=${only_kyc_full}&price=${orderprice}&sepa_option=${sepa_option}&type=buy"

X_API_SIGNATURE=$(sign "${http_method}" "${uri}" "${X_API_KEY}" "${concatted_post_parameters}" "${secret}")
#~ response=$( curl ${uri} -H "X-API-KEY: ${X_API_KEY}" -H "X-API-NONCE: ${X_API_NONCE}" -H "X-API-SIGNATURE: ${X_API_SIGNATURE}" )

## fee
# curl-response: {"min_network_fee":"0.00000402","errors":[],"credits":98}
http_method="GET"
uri="https://api.bitcoin.de/v4/btc/withdrawals/min_network_fee"
X_API_SIGNATURE=$(sign "${http_method}" "${uri}" "${X_API_KEY}" "" "${secret}")

response=$( curl ${uri} -H "X-API-KEY: ${X_API_KEY}" -H "X-API-NONCE: ${X_API_NONCE}" -H "X-API-SIGNATURE: ${X_API_SIGNATURE}" )
network_fee=$(echo ${response} |jq -r '.min_network_fee')

## withdrawal
http_method="POST"
uri="https://api.bitcoin.de/v4/btc/withdrawals"
address="bc1q…"
amount="0.01"
#~ comment="stacking sats" # optional, readable on bitcoin.de only
#~ network_fee # set to minium as above
concatted_post_parameters="address=${address}&amount=${amount}&network_fee=${network_fee}"
X_API_SIGNATURE=$(sign "${http_method}" "${uri}" "${X_API_KEY}" "${concatted_post_parameters}" "${secret}")

#~ response=$( curl ${uri} -H "X-API-KEY: ${X_API_KEY}" -H "X-API-NONCE: ${X_API_NONCE}" -H "X-API-SIGNATURE: ${X_API_SIGNATURE}" )
