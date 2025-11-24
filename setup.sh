#!/bin/bash
#
# LDAP TOTP schema setup script
#
# Downloads the latest release of ldap-totp-schema from GitHub and modifies
# the LDIF files to use your base DN.
#
# Usage: ./setup.sh
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
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
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

    # Files to process
    local files=("totp-acls.ldif" "service-account.ldif")

    for file in "${files[@]}"; do
        if [ -f "${source_dir}/${file}" ]; then
            # Replace default base DN with user's base DN
            sed "s/${DEFAULT_BASE_DN}/${BASE_DN}/g" "${source_dir}/${file}" > "${output_dir}/${file}"
            print_success "Created ${output_dir}/${file}"
        else
            print_warning "File not found: ${file}"
        fi
    done

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
    echo "  totp-schema.ldif      - TOTP attributes and object classes"
    echo "  totp-acls.ldif        - Access control rules (customised for ${BASE_DN})"
    echo "  service-account.ldif  - PAM service account (customised for ${BASE_DN})"
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
    echo "3. Apply access controls:"
    echo "   sudo ldapmodify -Y EXTERNAL -H ldapi:/// -f ${output_dir}/totp-acls.ldif"
    echo ""
    echo "For osixia/openldap Docker container, see the README for volume mount instructions."
    echo ""
}

# Main
main() {
    echo ""
    echo "LDAP TOTP Schema Setup"
    echo "======================"

    check_dependencies
    get_base_dn

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
