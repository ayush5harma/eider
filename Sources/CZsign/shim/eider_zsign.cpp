// Eider's C wrapper over zsign and OpenSSL. See include/eider_zsign.h.

#include "eider_zsign.h"

#include "bundle.h"
#include "common.h"
#include "openssl.h"

#include <OpenSSL/err.h>
#include <OpenSSL/ocsp.h>
#include <OpenSSL/pem.h>
#include <OpenSSL/pkcs12.h>
#include <OpenSSL/provider.h>
#include <OpenSSL/x509v3.h>

#include <ctime>
#include <mutex>

namespace {

// Five minutes of clock skew either way. A response older than a week is
// refused even without nextUpdate: the request has no nonce, so over plain
// HTTP an old "good" could otherwise be replayed after a revocation.
const long kClockSkewSeconds = 300;
const long kMaxResponseAgeSeconds = 7 * 24 * 3600;

// OpenSSL 3 stops loading the default provider by itself once any provider
// is loaded explicitly, and Keychain-exported p12s may use RC2-40, which
// lives in the legacy provider. Load both, once.
void LoadProviders()
{
	static std::once_flag once;
	std::call_once(once, [] {
		OSSL_PROVIDER_load(NULL, "default");
		OSSL_PROVIDER_load(NULL, "legacy");
	});
}

char* CopyString(const string& value)
{
	return strdup(value.c_str());
}

void SetError(char** error, const string& message)
{
	if (NULL != error) {
		*error = CopyString(message);
	}
}

// zsign's messages look like ">>> Can't find TeamId!\n".
string CleanZsignMessage(string message)
{
	if (0 == message.rfind(">>>", 0)) {
		message.erase(0, 3);
	}
	size_t first = message.find_first_not_of(" \t\r\n");
	size_t last = message.find_last_not_of(" \t\r\n");
	if (string::npos == first) {
		return "";
	}
	return message.substr(first, last - first + 1);
}

bool CopyDER(X509* cert, eider_bytes* out)
{
	unsigned char* der = NULL;
	int length = i2d_X509(cert, &der);
	if (length <= 0 || NULL == der) {
		return false;
	}
	out->bytes = (uint8_t*)malloc((size_t)length);
	if (NULL == out->bytes) {
		OPENSSL_free(der);
		return false;
	}
	memcpy(out->bytes, der, (size_t)length);
	out->length = (size_t)length;
	OPENSSL_free(der);
	return true;
}

X509* ReadDER(const uint8_t* bytes, size_t length)
{
	if (NULL == bytes || 0 == length) {
		return NULL;
	}
	const unsigned char* cursor = bytes;
	return d2i_X509(NULL, &cursor, (long)length);
}

X509* ReadPEM(const char* pem)
{
	BIO* bio = BIO_new_mem_buf(pem, (int)strlen(pem));
	if (NULL == bio) {
		return NULL;
	}
	X509* cert = PEM_read_bio_X509(bio, NULL, NULL, NULL);
	BIO_free(bio);
	return cert;
}

// True only when candidate's key really signed leaf: X509_check_issued
// compares names and key ids, which a crafted p12 chain can copy.
bool Issued(X509* candidate, X509* leaf)
{
	EVP_PKEY* key = X509_get0_pubkey(candidate);
	return X509_V_OK == X509_check_issued(candidate, leaf) && NULL != key && 1 == X509_verify(leaf, key);
}

// The issuer is the only OCSP trust anchor, so it must have signed the leaf.
// zsign's Apple WWDR intermediates first, then the p12's own chain (needed
// for any non-Apple CA, such as the one the tests make).
X509* FindIssuer(X509* leaf, STACK_OF(X509)* chain)
{
	const char* pem = ZSignAsset::WWDRIntermediatePEM(X509_issuer_name_hash(leaf));
	X509* wwdr = (NULL != pem) ? ReadPEM(pem) : NULL;
	if (NULL != wwdr && Issued(wwdr, leaf)) {
		return wwdr;
	}
	X509_free(wwdr);
	for (int i = 0; NULL != chain && i < sk_X509_num(chain); i++) {
		X509* candidate = sk_X509_value(chain, i);
		if (Issued(candidate, leaf)) {
			X509_up_ref(candidate);
			return candidate;
		}
	}
	return NULL;
}

bool ErrorQueueHasMACFailure()
{
	unsigned long code = 0;
	bool found = false;
	while (0 != (code = ERR_get_error())) {
		if (ERR_LIB_PKCS12 == ERR_GET_LIB(code) && PKCS12_R_MAC_VERIFY_FAILURE == ERR_GET_REASON(code)) {
			found = true;
		}
	}
	return found;
}

int64_t TimeToEpoch(const ASN1_TIME* time)
{
	struct tm value;
	memset(&value, 0, sizeof(value));
	if (NULL == time || 1 != ASN1_TIME_to_tm(time, &value)) {
		return 0;
	}
	return (int64_t)timegm(&value);
}

} // namespace

extern "C" {

void eider_bytes_free(eider_bytes* value)
{
	if (NULL == value) {
		return;
	}
	free(value->bytes);
	value->bytes = NULL;
	value->length = 0;
}

void eider_string_free(char* value)
{
	free(value);
}

eider_p12_status eider_p12_read(const uint8_t* p12, size_t p12_length,
								const char* password,
								eider_bytes* leaf_der, eider_bytes* issuer_der)
{
	LoadProviders();
	*leaf_der = eider_bytes{NULL, 0};
	*issuer_der = eider_bytes{NULL, 0};

	const unsigned char* cursor = p12;
	PKCS12* container = d2i_PKCS12(NULL, &cursor, (long)p12_length);
	if (NULL == container) {
		ERR_clear_error();
		return EIDER_P12_MALFORMED;
	}

	ERR_clear_error();
	EVP_PKEY* key = NULL;
	X509* leaf = NULL;
	STACK_OF(X509)* chain = NULL;
	// Without a MAC, a wrong password only shows as a decryption failure.
	bool hasMAC = (1 == PKCS12_mac_present(container));
	int parsed = PKCS12_parse(container, NULL == password ? "" : password, &key, &leaf, &chain);
	PKCS12_free(container);
	if (!parsed) {
		bool wrongPassword = ErrorQueueHasMACFailure() || !hasMAC;
		return wrongPassword ? EIDER_P12_WRONG_PASSWORD : EIDER_P12_MALFORMED;
	}

	eider_p12_status status = EIDER_P12_OK;
	if (NULL == key || NULL == leaf || !X509_check_private_key(leaf, key)) {
		status = EIDER_P12_NO_IDENTITY;
	} else if (!CopyDER(leaf, leaf_der)) {
		status = EIDER_P12_MALFORMED;
	} else {
		X509* issuer = FindIssuer(leaf, chain);
		if (NULL != issuer) {
			CopyDER(issuer, issuer_der);
			X509_free(issuer);
		}
	}

	EVP_PKEY_free(key);
	X509_free(leaf);
	sk_X509_pop_free(chain, X509_free);
	ERR_clear_error();
	return status;
}

int eider_ocsp_request(const uint8_t* leaf_bytes, size_t leaf_length,
					   const uint8_t* issuer_bytes, size_t issuer_length,
					   eider_bytes* request_der, char** responder_url,
					   char** error)
{
	*request_der = eider_bytes{NULL, 0};
	*responder_url = NULL;

	X509* leaf = ReadDER(leaf_bytes, leaf_length);
	X509* issuer = ReadDER(issuer_bytes, issuer_length);
	if (NULL == leaf || NULL == issuer) {
		X509_free(leaf);
		X509_free(issuer);
		SetError(error, "The certificate or its issuer could not be read.");
		return -1;
	}

	string url;
	AUTHORITY_INFO_ACCESS* access = (AUTHORITY_INFO_ACCESS*)X509_get_ext_d2i(leaf, NID_info_access, NULL, NULL);
	for (int i = 0; NULL != access && i < sk_ACCESS_DESCRIPTION_num(access); i++) {
		ACCESS_DESCRIPTION* description = sk_ACCESS_DESCRIPTION_value(access, i);
		if (NID_ad_OCSP == OBJ_obj2nid(description->method) && GEN_URI == description->location->type) {
			ASN1_IA5STRING* uri = description->location->d.uniformResourceIdentifier;
			url.assign((const char*)ASN1_STRING_get0_data(uri), (size_t)ASN1_STRING_length(uri));
			break;
		}
	}
	AUTHORITY_INFO_ACCESS_free(access);
	if (url.empty()) {
		X509_free(leaf);
		X509_free(issuer);
		SetError(error, "The certificate names no OCSP responder.");
		return -1;
	}

	int result = -1;
	OCSP_REQUEST* request = OCSP_REQUEST_new();
	OCSP_CERTID* identifier = OCSP_cert_to_id(EVP_sha1(), leaf, issuer);
	if (NULL != request && NULL != identifier && NULL != OCSP_request_add0_id(request, identifier)) {
		identifier = NULL; // owned by the request now
		unsigned char* der = NULL;
		int length = i2d_OCSP_REQUEST(request, &der);
		if (length > 0 && NULL != der) {
			request_der->bytes = (uint8_t*)malloc((size_t)length);
			if (NULL != request_der->bytes) {
				memcpy(request_der->bytes, der, (size_t)length);
				request_der->length = (size_t)length;
				*responder_url = CopyString(url);
				result = 0;
			}
			OPENSSL_free(der);
		}
	}
	if (0 != result) {
		SetError(error, "The OCSP request could not be built.");
	}
	OCSP_CERTID_free(identifier);
	OCSP_REQUEST_free(request);
	X509_free(leaf);
	X509_free(issuer);
	ERR_clear_error();
	return result;
}

eider_ocsp_status eider_ocsp_check(const uint8_t* response_bytes, size_t response_length,
								   const uint8_t* leaf_bytes, size_t leaf_length,
								   const uint8_t* issuer_bytes, size_t issuer_length,
								   int64_t* revoked_at, char** error)
{
	*revoked_at = 0;
	X509* leaf = ReadDER(leaf_bytes, leaf_length);
	X509* issuer = ReadDER(issuer_bytes, issuer_length);
	const unsigned char* cursor = response_bytes;
	OCSP_RESPONSE* response = d2i_OCSP_RESPONSE(NULL, &cursor, (long)response_length);
	OCSP_BASICRESP* basic = NULL;
	X509_STORE* store = NULL;
	STACK_OF(X509)* known = NULL;
	OCSP_CERTID* identifier = NULL;
	eider_ocsp_status status = EIDER_OCSP_UNKNOWN;
	string reason;

	if (NULL == leaf || NULL == issuer) {
		reason = "The certificate or its issuer could not be read.";
	} else if (NULL == response) {
		reason = "The OCSP responder sent something that is not an OCSP response.";
	} else if (OCSP_RESPONSE_STATUS_SUCCESSFUL != OCSP_response_status(response)) {
		reason = string("The OCSP responder refused the request (") + OCSP_response_status_str(OCSP_response_status(response)) + ").";
	} else if (NULL == (basic = OCSP_response_get1_basic(response))) {
		reason = "The OCSP response has no status in it.";
	} else {
		// Trust anchors: only the issuer. PARTIAL_CHAIN lets that intermediate
		// stand as the anchor, so the response must come from the issuer itself
		// or a responder it delegated to; a forged "good" from anyone else on
		// the plain-HTTP path is rejected.
		store = X509_STORE_new();
		known = sk_X509_new_null();
		if (NULL != store && NULL != known) {
			X509_STORE_add_cert(store, issuer);
			X509_STORE_set_flags(store, X509_V_FLAG_PARTIAL_CHAIN);
			sk_X509_push(known, issuer);
		}
		int certStatus = -1;
		int revocationReason = -1;
		ASN1_GENERALIZEDTIME* revokedTime = NULL;
		ASN1_GENERALIZEDTIME* thisUpdate = NULL;
		ASN1_GENERALIZEDTIME* nextUpdate = NULL;
		identifier = OCSP_cert_to_id(EVP_sha1(), leaf, issuer);
		if (NULL == store || NULL == known || NULL == identifier) {
			reason = "Out of memory while checking the OCSP response.";
		} else if (1 != OCSP_basic_verify(basic, known, store, 0)) {
			reason = "The OCSP response is not signed by the certificate's issuer.";
		} else if (1 != OCSP_resp_find_status(basic, identifier, &certStatus, &revocationReason, &revokedTime, &thisUpdate, &nextUpdate)) {
			reason = "The OCSP response does not mention this certificate.";
		} else if (1 != OCSP_check_validity(thisUpdate, nextUpdate, kClockSkewSeconds, kMaxResponseAgeSeconds)) {
			reason = "The OCSP response is out of date.";
		} else if (V_OCSP_CERTSTATUS_GOOD == certStatus) {
			status = EIDER_OCSP_GOOD;
		} else if (V_OCSP_CERTSTATUS_REVOKED == certStatus) {
			status = EIDER_OCSP_REVOKED;
			*revoked_at = TimeToEpoch(revokedTime);
		} else {
			reason = "The OCSP responder does not know this certificate.";
		}
	}

	if (EIDER_OCSP_UNKNOWN == status) {
		SetError(error, reason);
	}
	OCSP_CERTID_free(identifier);
	sk_X509_free(known); // the issuer itself is freed below
	X509_STORE_free(store);
	OCSP_BASICRESP_free(basic);
	OCSP_RESPONSE_free(response);
	X509_free(leaf);
	X509_free(issuer);
	ERR_clear_error();
	return status;
}

int eider_sign_app(const eider_sign_request* request, char** error)
{
	LoadProviders();
	ZLog::SetLogLever(ZLog::E_NONE);
	ZLog::ClearLastError();

	// SHA-1 plus SHA-256 CodeDirectories (bSHA256Only = false, zsign's
	// --legacy_sha1), which codesign -dvvv shows as "Hash choices=sha1,sha256".
	// iOS accepts either; the dual form is what EiderSign was asked to emit.
	ZSignAsset asset;
	bool signedOK = asset.Init("", request->p12_path, request->profile_path, "",
							   NULL == request->password ? "" : request->password,
							   false, false, false);
	if (signedOK) {
		ZBundle bundle;
		bundle.m_bEnableDocuments = (0 != request->enable_documents);
		bundle.m_bRemoveUISupportedDevices = (0 != request->remove_supported_devices);
		// bForce: always re-sign every file. bEnableCache: zsign's cache lives
		// in the working directory, which is "/" on iOS and not writable.
		signedOK = bundle.SignFolder(&asset, request->app_path,
									 NULL == request->bundle_id ? "" : request->bundle_id,
									 NULL == request->version ? "" : request->version,
									 NULL == request->display_name ? "" : request->display_name,
									 vector<string>(), vector<string>(),
									 true, false, false, false);
	}

	if (!signedOK) {
		string message = CleanZsignMessage(ZLog::LastError());
		SetError(error, message.empty() ? "zsign could not sign the app." : message);
	}
	ERR_clear_error();
	return signedOK ? 0 : -1;
}

} // extern "C"
