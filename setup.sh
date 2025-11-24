#!/bin/bash
#
# LDAP TOTP schema setup script
#
# Downloads the latest release of ldap-totp-schema from GitHub and modifies
# the LDIF files to use your base DN.
#
# Usage:
#   ./setup.sh                          # Interactive prompt for base DN
#   ./setup.sh dc=example,dc=com        # Provide base DN as argument
#   curl ... | bash -s -- dc=example,dc=com  # Pipe with argument
#

set -e

REPO="wheelybird/ldap-totp-schema"
GITHUB_API="https://api.github.com/repos/${REPO}/releases/latest"
DEFAULT_BASE_DN="dc=example,dc=com"

# Colours for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No colour

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1" >&2
}

print_success() {
    echo -e "${GREEN}[OK]${NC} $1" >&2
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" >&2
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Check for required tools
check_dependencies() {
    local missing=()

    for cmd in curl sed; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        print_error "Missing required tools: ${missing[*]}"
        echo "Please install them and try again."
        exit 1
    fi
}

# Validate base DN format
validate_base_dn() {
    local dn="$1"

    # Check for basic DN format (dc=something or o=something or ou=something)
    if [[ ! "$dn" =~ ^(dc|o|ou|c)=[a-zA-Z0-9._-]+(,(dc|o|ou|c)=[a-zA-Z0-9._-]+)*$ ]]; then
        return 1
    fi

    return 0
}

# Prompt for base DN
get_base_dn() {
    # If base DN was provided as argument, use it
    if [ -n "$1" ]; then
        BASE_DN="$1"
        if validate_base_dn "$BASE_DN"; then
            print_info "Using base DN: $BASE_DN"
            return 0
        else
            print_error "Invalid base DN format: $BASE_DN"
            print_error "Please use format like 'dc=example,dc=com'"
            exit 1
        fi
    fi

    # Check if we can read from terminal
    if [ ! -t 0 ]; then
        # stdin is not a terminal (e.g., piped from curl)
        # Try to read from /dev/tty
        if [ -e /dev/tty ]; then
            exec < /dev/tty
        else
            print_error "No terminal available for input."
            print_error "Please provide base DN as argument:"
            echo "  curl -sL https://raw.githubusercontent.com/wheelybird/ldap-totp-schema/main/setup.sh | bash -s -- dc=example,dc=com"
            exit 1
        fi
    fi

    echo ""
    echo "Enter your LDAP base DN."
    echo "Examples:"
    echo "  dc=luminary,dc=id"
    echo "  dc=example,dc=com"
    echo "  o=myorganisation"
    echo ""

    while true; do
        read -p "Base DN: " BASE_DN

        if [ -z "$BASE_DN" ]; then
            print_error "Base DN cannot be empty"
            continue
        fi

        if validate_base_dn "$BASE_DN"; then
            break
        else
            print_error "Invalid base DN format. Please use format like 'dc=example,dc=com'"
        fi
    done

    echo ""
    print_info "Using base DN: $BASE_DN"
}

# Generate a random password
generate_password() {
    local length="${1:-32}"
    local password=""

    # Try native bash with /dev/urandom first
    if [ -r /dev/urandom ]; then
        password=$(tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c "$length")
        if [ ${#password} -eq "$length" ]; then
            echo "$password"
            return 0
        fi
    fi

    # Fall back to openssl if available
    if command -v openssl &> /dev/null; then
        password=$(openssl rand -base64 48 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c "$length")
        if [ -n "$password" ]; then
            echo "$password"
            return 0
        fi
    fi

    # Fall back to $RANDOM (less secure but works everywhere)
    password=""
    local chars='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
    for _ in $(seq 1 "$length"); do
        password="${password}${chars:RANDOM%${#chars}:1}"
    done
    echo "$password"
}

# Hash password for LDAP if slappasswd is available
hash_password() {
    local password="$1"

    # Try slappasswd (OpenLDAP)
    if command -v slappasswd &> /dev/null; then
        local hashed
        hashed=$(slappasswd -s "$password" 2>/dev/null)
        if [ -n "$hashed" ]; then
            echo "$hashed"
            return 0
        fi
    fi

    # No hashing available - return empty to indicate failure
    return 1
}

# Download latest release or fallback to main branch
download_schema() {
    local temp_dir
    temp_dir=$(mktemp -d)

    print_info "Checking for latest release..."

    # Try to get latest release
    local release_url
    release_url=$(curl -s "$GITHUB_API" | grep "tarball_url" | head -1 | cut -d '"' -f 4)

    if [ -n "$release_url" ] && [ "$release_url" != "null" ]; then
        print_info "Downloading latest release..."
        if curl -sL "$release_url" | tar xz -C "$temp_dir" --strip-components=1; then
            print_success "Downloaded latest release"
            echo "$temp_dir"
            return 0
        fi
    fi

    # Fallback to main branch
    print_warning "No release found, downloading from main branch..."
    local main_url="https://github.com/${REPO}/archive/refs/heads/main.tar.gz"

    if curl -sL "$main_url" | tar xz -C "$temp_dir" --strip-components=1; then
        print_success "Downloaded from main branch"
        echo "$temp_dir"
        return 0
    fi

    print_error "Failed to download schema files"
    rm -rf "$temp_dir"
    exit 1
}

# Modify LDIF files to use user's base DN
modify_files() {
    local source_dir="$1"
    local output_dir="$2"

    print_info "Modifying LDIF files for base DN: $BASE_DN"

    # Create output directory if it doesn't exist
    mkdir -p "$output_dir"

    # Process totp-acls.ldif
    if [ -f "${source_dir}/totp-acls.ldif" ]; then
        sed "s/${DEFAULT_BASE_DN}/${BASE_DN}/g" "${source_dir}/totp-acls.ldif" > "${output_dir}/totp-acls.ldif"
        print_success "Created ${output_dir}/totp-acls.ldif"
    else
        print_warning "File not found: totp-acls.ldif"
    fi

    # Process service-account.ldif with generated password
    if [ -f "${source_dir}/service-account.ldif" ]; then
        print_info "Generating service account password..."

        # Generate password
        SERVICE_PASSWORD=$(generate_password 32)

        # Try to hash it
        local password_value
        if HASHED_PASSWORD=$(hash_password "$SERVICE_PASSWORD"); then
            password_value="$HASHED_PASSWORD"
            print_success "Password hashed with slappasswd"
        else
            # Can't hash - use plaintext with warning
            password_value="$SERVICE_PASSWORD"
            print_warning "slappasswd not available - password stored in plaintext"
            print_warning "Consider hashing it later with: slappasswd -s <password>"
        fi

        # Replace base DN and password placeholder
        sed -e "s/${DEFAULT_BASE_DN}/${BASE_DN}/g" \
            -e "s/{SSHA}YourHashedPasswordHere/${password_value}/g" \
            "${source_dir}/service-account.ldif" > "${output_dir}/service-account.ldif"
        print_success "Created ${output_dir}/service-account.ldif"

        # Save password to file with restricted permissions
        local password_file="${output_dir}/service-account-password.txt"
        (
            umask 077
            cat > "$password_file" << EOF
# Service account password for LDAP TOTP authentication
# Generated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
#
# Account DN: cn=nslcd,ou=services,${BASE_DN}
#
# IMPORTANT: Keep this file secure and delete after configuring your services.

Password: ${SERVICE_PASSWORD}
EOF
        )
        print_success "Created ${password_file} (mode 600)"
    else
        print_warning "File not found: service-account.ldif"
    fi

    # Copy schema file (doesn't need modification)
    if [ -f "${source_dir}/totp-schema.ldif" ]; then
        cp "${source_dir}/totp-schema.ldif" "${output_dir}/totp-schema.ldif"
        print_success "Created ${output_dir}/totp-schema.ldif"
    fi
}

# Display summary and next steps
show_summary() {
    local output_dir="$1"

    echo ""
    echo "=========================================="
    echo -e "${GREEN}Setup complete!${NC}"
    echo "=========================================="
    echo ""
    echo "Files created in: ${output_dir}"
    echo ""
    echo "  totp-schema.ldif              - TOTP attributes and object classes"
    echo "  totp-acls.ldif                - Access control rules (customised for ${BASE_DN})"
    echo "  service-account.ldif          - PAM service account (customised for ${BASE_DN})"
    echo "  service-account-password.txt  - Service account password (KEEP SECURE)"
    echo ""
    echo -e "${YELLOW}IMPORTANT:${NC} The service account password has been saved to:"
    echo "  ${output_dir}/service-account-password.txt"
    echo ""
    echo "  Store this password securely and delete the file after configuring your services."
    echo ""
    echo "Next steps:"
    echo ""
    echo "1. Review and adjust the ACLs in totp-acls.ldif:"
    echo "   - Update the admin group DN if needed"
    echo "   - Update the service account DN if needed"
    echo ""
    echo "2. Add schema to OpenLDAP:"
    echo "   sudo ldapadd -Y EXTERNAL -H ldapi:/// -f ${output_dir}/totp-schema.ldif"
    echo ""
    echo "3. Create the services OU and service account:"
    echo "   ldapadd -x -D \"cn=admin,${BASE_DN}\" -W -f ${output_dir}/service-account.ldif"
    echo ""
    echo "4. Apply access controls:"
    echo "   sudo ldapmodify -Y EXTERNAL -H ldapi:/// -f ${output_dir}/totp-acls.ldif"
    echo ""
    echo "For osixia/openldap Docker container, see the README for volume mount instructions."
    echo ""
}

# Show usage
show_usage() {
    echo "Usage: $0 [BASE_DN]"
    echo ""
    echo "Arguments:"
    echo "  BASE_DN    Your LDAP base DN (e.g., dc=example,dc=com)"
    echo ""
    echo "Examples:"
    echo "  $0                           # Interactive prompt"
    echo "  $0 dc=luminary,dc=id         # Non-interactive"
    echo "  curl -sL URL | bash -s -- dc=example,dc=com"
    echo ""
}

# Main
main() {
    # Handle --help
    if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
        show_usage
        exit 0
    fi

    echo ""
    echo "LDAP TOTP Schema Setup"
    echo "======================"

    check_dependencies
    get_base_dn "$1"

    # Determine output directory
    OUTPUT_DIR="./ldap-totp-schema-configured"

    # Download schema files
    TEMP_DIR=$(download_schema)

    # Modify files
    modify_files "$TEMP_DIR" "$OUTPUT_DIR"

    # Cleanup
    rm -rf "$TEMP_DIR"

    # Show summary
    show_summary "$OUTPUT_DIR"
}

main "$@"
