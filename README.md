# LDAP TOTP Schema

OpenLDAP schema for storing TOTP (Time-based One-Time Password) secrets and managing multi-factor authentication policies in your LDAP directory.

## Overview

This schema extends your LDAP directory with attributes and object classes for implementing TOTP-based two-factor authentication. It provides a centralised, secure location for storing TOTP secrets and enforcing MFA policies across your infrastructure.

**Use cases:**
- Centralised TOTP secret storage for authentication systems
- MFA policy enforcement at the group level
- Grace period management for new user onboarding
- Backup code storage for account recovery
- Integration with PAM, web applications, VPN servers, or custom authentication systems

## Schema Contents

### Attributes

| Attribute | OID | Type | Description |
|-----------|-----|------|-------------|
| `totpSecret` | 1.3.6.1.4.1.64419.1.1.1 | Single-value | TOTP shared secret (Base32 encoded, e.g., `JBSWY3DPEHPK3PXP`) |
| `totpScratchCode` | 1.3.6.1.4.1.64419.1.1.2 | Multi-value | Backup/recovery codes for emergency access (8-digit codes with `TOTP-SCRATCH:` prefix) |
| `totpEnrolledDate` | 1.3.6.1.4.1.64419.1.1.3 | Single-value | Timestamp when user enrolled in MFA (GeneralisedTime format) |
| `totpStatus` | 1.3.6.1.4.1.64419.1.1.4 | Single-value | Enrolment status: `none`, `pending`, `active`, `disabled`, `bypassed` |
| `mfaRequired` | 1.3.6.1.4.1.64419.1.1.5 | Single-value | Boolean flag for group-level MFA requirement |
| `mfaGracePeriodDays` | 1.3.6.1.4.1.64419.1.1.6 | Single-value | Number of days grace period before MFA enforcement |

### Object Classes

| Object Class | OID | Type | Attributes |
|--------------|-----|------|------------|
| `totpUser` | 1.3.6.1.4.1.64419.1.2.1 | Auxiliary | `totpSecret`, `totpScratchCode`, `totpEnrolledDate`, `totpStatus` |
| `mfaGroup` | 1.3.6.1.4.1.64419.1.2.2 | Auxiliary | `mfaRequired`, `mfaGracePeriodDays` |

**Note:** Both object classes are auxiliary, meaning they extend existing user and group entries without replacing the structural object class.

## Installation

### 1. Add Schema to OpenLDAP

```bash
ldapadd -Y EXTERNAL -H ldapi:/// -f totp-schema.ldif
```

**Verify installation:**
```bash
ldapsearch -Y EXTERNAL -H ldapi:/// -b "cn=schema,cn=config" "(cn=*totp*)"
# Should return: cn=totp,cn=schema,cn=config
```

### 2. Configure Access Controls (Optional but Recommended)

The `totp-acls.ldif` file provides secure access controls for TOTP secrets. Edit the file to match your directory structure:

```bash
# Edit totp-acls.ldif and replace:
# - dc=example,dc=com with your base DN
# - ou=services,dc=example,dc=com with your services OU (if applicable)

ldapmodify -Y EXTERNAL -H ldapi:/// -f totp-acls.ldif
```

**Access control summary:**
- `totpSecret`: Writable by self and admins; readable by designated service accounts
- `totpScratchCode`: Readable by self; writable by admins and service accounts (to remove used codes)
- `totpStatus`, `totpEnrolledDate`: Readable by self, admins, and authorised services; writable by admins
- `mfaRequired`, `mfaGracePeriodDays`: Readable by all authenticated users; writable by admins

### 3. Create Service Account for PAM Authentication

If you're using this schema with PAM modules (such as `libpam-ldapd` for password authentication and a custom TOTP PAM module for OTP verification), you'll need a service account that can:

- Bind to LDAP and search for users (for password authentication)
- Read `totpSecret` for OTP verification
- Read `totpStatus` to check if MFA is enabled
- Write to `totpScratchCode` to remove used backup codes

**Create the service account:**

```bash
ldapadd -x -D "cn=admin,dc=example,dc=com" -w admin_password -f service-account.ldif
```

**Generate a secure password for the service account:**

```bash
# Generate a random password
PASSWORD=$(openssl rand -base64 32)
echo "Service account password: $PASSWORD"

# Hash it for LDAP
HASHED=$(slappasswd -s "$PASSWORD")
echo "Hashed password: $HASHED"

# Update the service-account.ldif file with the hashed password
# or use ldapmodify to update it after creation
```

**Configure PAM to use this service account:**

In `/etc/nslcd.conf`:
```conf
uri ldap://your-ldap-server.example.com
base dc=example,dc=com
binddn cn=nslcd,ou=services,dc=example,dc=com
bindpw your-service-account-password

# Enable TLS for secure connections
ssl start_tls
tls_reqcert demand
tls_cacertfile /etc/ssl/certs/ca-certificates.crt
```

**Required ACLs for PAM integration:**

Your `totp-acls.ldif` should include these rules (adjust to match your service account DN):

```ldif
# User passwords - allow service account to authenticate users
olcAccess: {0}to attrs=userPassword
  by self write
  by anonymous auth
  by group.exact="cn=admins,ou=groups,dc=example,dc=com" write
  by dn.exact="cn=nslcd,ou=services,dc=example,dc=com" auth
  by * none

# TOTP secret - read-only for OTP verification
olcAccess: {1}to attrs=totpSecret
  by self write
  by group.exact="cn=admins,ou=groups,dc=example,dc=com" write
  by dn.exact="cn=nslcd,ou=services,dc=example,dc=com" read
  by * none

# TOTP scratch codes - write access to remove used codes
olcAccess: {2}to attrs=totpScratchCode
  by self read
  by group.exact="cn=admins,ou=groups,dc=example,dc=com" write
  by dn.exact="cn=nslcd,ou=services,dc=example,dc=com" write
  by * none

# TOTP status and enrolment - read access to check if MFA is active
olcAccess: {3}to attrs=totpStatus,totpEnrolledDate
  by self read
  by group.exact="cn=admins,ou=groups,dc=example,dc=com" write
  by dn.exact="cn=nslcd,ou=services,dc=example,dc=com" read
  by * none

# MFA policy attributes - check if MFA is required
olcAccess: {4}to attrs=mfaRequired,mfaGracePeriodDays
  by group.exact="cn=admins,ou=groups,dc=example,dc=com" write
  by users read
  by * none

# General user attributes - service account needs to search for users
olcAccess: {5}to dn.subtree="ou=people,dc=example,dc=com"
  by dn.exact="cn=nslcd,ou=services,dc=example,dc=com" read
  by * break
```

## Usage Examples

### Enable MFA for a User

**Step 1: Generate a TOTP secret**

Generate a 160-bit (32-character Base32) secret:
```bash
# Using OpenSSL and base32 encoding
SECRET=$(openssl rand -base64 20 | base32 | tr -d '=' | head -c 32)
echo $SECRET
# Example output: JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP
```

**Step 2: Add TOTP attributes to user**

```bash
ldapmodify -x -D "cn=admin,dc=example,dc=com" -w admin_password <<EOF
dn: uid=jdoe,ou=people,dc=example,dc=com
changetype: modify
add: objectClass
objectClass: totpUser
-
add: totpSecret
totpSecret: JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP
-
add: totpStatus
totpStatus: active
-
add: totpEnrolledDate
totpEnrolledDate: 20251020120000Z
EOF
```

**Step 3: Generate QR code for user enrolment**

The user scans this with their authenticator app (Google Authenticator, Authy, etc.):

```
otpauth://totp/Example:jdoe?secret=JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP&issuer=Example&algorithm=SHA1&digits=6&period=30
```

Generate QR code:
```bash
# Using qrencode
echo "otpauth://totp/Example:jdoe?secret=JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP&issuer=Example" | qrencode -t UTF8
```

### Add Backup Codes

Generate and store 10 backup codes for emergency access:

```bash
# Generate backup codes (8 digits each)
for i in {1..10}; do
  printf "TOTP-SCRATCH:%08d\n" $((RANDOM * RANDOM % 100000000))
done

# Add to user entry
ldapmodify -x -D "cn=admin,dc=example,dc=com" -w admin_password <<EOF
dn: uid=jdoe,ou=people,dc=example,dc=com
changetype: modify
add: totpScratchCode
totpScratchCode: TOTP-SCRATCH:12345678
totpScratchCode: TOTP-SCRATCH:87654321
totpScratchCode: TOTP-SCRATCH:11223344
totpScratchCode: TOTP-SCRATCH:44332211
totpScratchCode: TOTP-SCRATCH:56789012
totpScratchCode: TOTP-SCRATCH:21098765
totpScratchCode: TOTP-SCRATCH:98765432
totpScratchCode: TOTP-SCRATCH:23456789
totpScratchCode: TOTP-SCRATCH:34567890
totpScratchCode: TOTP-SCRATCH:45678901
EOF
```

**Important:** Backup codes should be one-time use. Your authentication system should delete them from LDAP after use.

### Enforce MFA for a Group

```bash
ldapmodify -x -D "cn=admin,dc=example,dc=com" -w admin_password <<EOF
dn: cn=admins,ou=groups,dc=example,dc=com
changetype: modify
add: objectClass
objectClass: mfaGroup
-
add: mfaRequired
mfaRequired: TRUE
-
add: mfaGracePeriodDays
mfaGracePeriodDays: 7
EOF
```

### Query User's MFA Status

```bash
ldapsearch -x -D "cn=admin,dc=example,dc=com" -w admin_password \
  -b "ou=people,dc=example,dc=com" \
  "(uid=jdoe)" totpStatus totpEnrolledDate totpSecret

# Returns:
# dn: uid=jdoe,ou=people,dc=example,dc=com
# totpStatus: active
# totpEnrolledDate: 20251020120000Z
# totpSecret: JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP
```

### Update MFA Status

**Disable MFA for user:**
```bash
ldapmodify -x -D "cn=admin,dc=example,dc=com" -w admin_password <<EOF
dn: uid=jdoe,ou=people,dc=example,dc=com
changetype: modify
replace: totpStatus
totpStatus: disabled
EOF
```

**Mark as pending (grace period active):**
```bash
ldapmodify -x -D "cn=admin,dc=example,dc=com" -w admin_password <<EOF
dn: uid=jdoe,ou=people,dc=example,dc=com
changetype: modify
replace: totpStatus
totpStatus: pending
-
replace: totpEnrolledDate
totpEnrolledDate: $(date -u +"%Y%m%d%H%M%SZ")
EOF
```

### Remove MFA from User

```bash
ldapmodify -x -D "cn=admin,dc=example,dc=com" -w admin_password <<EOF
dn: uid=jdoe,ou=people,dc=example,dc=com
changetype: modify
delete: totpSecret
-
delete: totpScratchCode
-
delete: totpStatus
-
delete: totpEnrolledDate
-
delete: objectClass
objectClass: totpUser
EOF
```

## TOTP Implementation Notes

### Secret Generation

- **Length:** 160 bits (32 Base32 characters) recommended by RFC 6238
- **Encoding:** Base32 (characters A-Z and 2-7)
- **Example:** `JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP`

### TOTP Parameters

Standard RFC 6238 parameters:
- **Algorithm:** SHA1 (widely supported)
- **Digits:** 6
- **Time Step:** 30 seconds

### Validation

When validating TOTP codes, account for clock drift by accepting codes from:
- Current time window
- Previous time window (30 seconds ago)
- Next time window (30 seconds ahead)

This provides a ±90 second tolerance window.

### Grace Period Logic

The grace period allows users time to set up MFA after account creation or MFA requirement:

1. Check if user is in group with `mfaRequired=TRUE`
2. If `totpStatus=pending`, check `totpEnrolledDate`
3. Calculate days elapsed: `(current_date - totpEnrolledDate) / 86400`
4. If days elapsed > `mfaGracePeriodDays`, enforce MFA requirement

## Security Considerations

### Secret Storage

- **Never** store TOTP secrets in plaintext in application code or logs
- Use LDAP ACLs to restrict `totpSecret` access to authorised services only
- Secrets should only be transmitted over TLS/SSL connections
- Consider using LDAP's built-in encryption (SSHA) for additional protection at rest

### Access Control

The provided `totp-acls.ldif` implements these security rules:
- Users can write their own `totpSecret` (for self-enrolment) and read their own `totpScratchCode` (to know remaining backup codes)
- Users **cannot** write their own `totpScratchCode` (prevents MFA bypass)
- Admins can read and write all TOTP attributes
- Service accounts need explicit permissions (see Installation section 3 for PAM integration example)
- Other users cannot read TOTP secrets or scratch codes

### Scratch Code Security

**Important security consideration:** Users are given read-only access to their scratch codes. This allows them to view how many backup codes remain, but prevents them from adding new codes to bypass MFA. Only administrators can add, modify, or manually remove scratch codes. The authentication service account can remove codes automatically when they are used during login.

## OID Registry

This schema uses OID prefix `1.3.6.1.4.1.64419` (IANA-assigned private enterprise number).

**OID Structure:**
```
1.3.6.1.4.1.64419           Enterprise number
1.3.6.1.4.1.64419.1         LDAP schema
1.3.6.1.4.1.64419.1.1.x     Attribute types
1.3.6.1.4.1.64419.1.2.x     Object classes
```

If you prefer to use your own enterprise number, you can:
1. Register at https://pen.iana.org/pen/PenApplication.page
2. Replace all instances of `1.3.6.1.4.1.64419` in `totp-schema.ldif`

## Troubleshooting

### Schema Already Exists

```
ldap_add: Other (e.g., implementation specific) error (80)
        additional info: olcAttributeTypes: Duplicate attributeType
```

**Cause:** Schema is already loaded in your directory.

**Solution:** Check existing schemas:
```bash
ldapsearch -Y EXTERNAL -H ldapi:/// -b "cn=schema,cn=config" "(cn=*totp*)"
```

### ACLs Not Working

```
ldap_search: Insufficient access (50)
```

**Cause:** ACLs are processed in order - first match wins.

**Solution:** Check ACL order and placement:
```bash
ldapsearch -Y EXTERNAL -H ldapi:/// -b "cn=config" "(olcAccess=*)" olcAccess
```

Ensure TOTP ACLs appear before more general "allow read" rules.

### Cannot Delete Schema

**Important:** LDAP schemas cannot be deleted once added.

**Workarounds:**
1. Stop using the attributes in your directory
2. Add new attributes with different OIDs if changes are needed
3. Migrate data to new attributes
4. (Last resort) Rebuild LDAP directory from scratch

## Standards & References

- **RFC 6238** - TOTP: Time-Based One-Time Password Algorithm
- **RFC 4226** - HOTP: HMAC-Based One-Time Password Algorithm
- **RFC 4512** - LDAP: Directory Information Models
- **RFC 4517** - LDAP: Syntaxes and Matching Rules
- **RFC 2252** - LDAP Attribute Syntax Definitions

## Licence

MIT Licence - see [LICENSE](LICENSE) file for details.

## Contributing

Contributions welcome! Please open an issue or pull request on GitHub.
