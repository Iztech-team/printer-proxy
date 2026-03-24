"""
Printer Discovery
==================
Discovers thermal printers via network scan (port 9100) and USB.

Network: Parallel TCP scan + multi-strategy MAC resolution.
USB: pyusb device enumeration with known vendor ID matching.

Works on Windows, Linux, and macOS.
"""

import socket
import subprocess
import re
import logging
import platform
from concurrent.futures import ThreadPoolExecutor, as_completed

logger = logging.getLogger(__name__)

_IS_WINDOWS = platform.system() == "Windows"

# Prevent console windows from flashing when running under pythonw.exe.
# Only pass creationflags on Windows — it's a Windows-only parameter.
_SUBPROCESS_KWARGS = (
    {"creationflags": subprocess.CREATE_NO_WINDOW} if _IS_WINDOWS else {}
)



# Known thermal printer USB vendor IDs
KNOWN_PRINTER_VENDORS = {
    0x04B8: "Epson",
    0x0519: "Star Micronics",
    0x0DD4: "Custom",
    0x0FE6: "ICS Electronics",  # Kontron/generic
    0x0416: "WinBond (POS)",
    0x0483: "STMicroelectronics (POS)",
    0x1504: "SNBC",
    0x1FC9: "NXP (POS)",
    0x20D1: "Dingding",
    0x0525: "Netchip (POS)",
    0x1A86: "QinHeng (CH340/POS)",
    0x28E9: "GD32 (POS)",
    0x0FE6: "ICS Electronics",
    0x0DD4: "Custom Engineering",
    0x04E8: "Samsung",
    0x04F9: "Brother",
    0x0B00: "Sewoo",
    0x0493: "ESC/POS compatible",
    0x0456: "Analog Devices (POS)",
}


class PrinterDiscovery:
    """Discover printers via network scan and USB enumeration."""

    PRINTER_PORT = 9100
    SCAN_TIMEOUT = 3  # seconds per host
    MAX_WORKERS = 50  # parallel scan threads

    def __init__(self, port=9100, timeout=3):
        self.PRINTER_PORT = port
        self.SCAN_TIMEOUT = timeout
        self._gateway_mac = None

    def scan(self, subnet=None):
        """
        Scan the local network for printers.
        Returns dict: { ip: { port, mac, responsive } }
        """
        if subnet is None:
            subnet = self._detect_subnet()

        if not subnet:
            logger.error("Could not detect network subnet.")
            return {}

        logger.info(f"Scanning {subnet}.0/24 on port {self.PRINTER_PORT}...")

        self._gateway_mac = self._detect_gateway_mac(subnet)
        if self._gateway_mac:
            logger.info(
                f"Gateway MAC detected: {self._gateway_mac} (will be ignored for printers)"
            )

        targets = [f"{subnet}.{i}" for i in range(1, 255)]

        found = {}
        with ThreadPoolExecutor(max_workers=self.MAX_WORKERS) as executor:
            futures = {
                executor.submit(self._check_port, ip, self.PRINTER_PORT): ip
                for ip in targets
            }
            for future in as_completed(futures):
                ip = futures[future]
                try:
                    is_open = future.result()
                    if is_open:
                        mac = self._get_real_mac(ip)
                        found[ip] = {
                            "port": self.PRINTER_PORT,
                            "mac": mac,
                            "responsive": True,
                        }
                        logger.info(f"  Found printer: {ip} (MAC: {mac or 'unknown'})")
                except Exception as e:
                    logger.debug(f"  Error scanning {ip}: {e}")

        logger.info(f"Scan complete. Found {len(found)} printer(s).")
        return found

    def check_printer(self, ip, port=None):
        """Check if a specific printer is reachable."""
        port = port or self.PRINTER_PORT
        return self._check_port(ip, port)

    def _check_port(self, ip, port):
        """Try to connect to ip:port. Returns True if open."""
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(self.SCAN_TIMEOUT)
            result = sock.connect_ex((ip, port))
            sock.close()
            return result == 0
        except (socket.timeout, OSError):
            return False

    def _detect_subnet(self):
        """Detect the local subnet (e.g., '192.168.1')."""
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect(("8.8.8.8", 80))
            local_ip = s.getsockname()[0]
            s.close()

            parts = local_ip.split(".")
            if len(parts) == 4:
                subnet = ".".join(parts[:3])
                logger.info(f"Local IP: {local_ip}, Subnet: {subnet}.0/24")
                return subnet
        except Exception as e:
            logger.error(f"Failed to detect subnet: {e}")

        return None

    # ─── Gateway detection ────────────────────────────────────

    def _detect_gateway_mac(self, subnet):
        """Find the default gateway's MAC so we can ignore it on printer entries."""
        gateway_ip = self._get_gateway_ip(subnet)
        if not gateway_ip:
            return None
        logger.info(f"Default gateway IP: {gateway_ip}")
        return self._get_arp_mac(gateway_ip)

    def _get_gateway_ip(self, subnet):
        """Get the default gateway IP address."""
        try:
            if _IS_WINDOWS:
                result = subprocess.run(
                    ["ipconfig"],
                    capture_output=True,
                    text=True,
                    timeout=10,
                    **_SUBPROCESS_KWARGS,
                )
                for line in result.stdout.splitlines():
                    if (
                        "default gateway" in line.lower()
                        or "passerelle par" in line.lower()
                    ):
                        match = re.search(r"(\d+\.\d+\.\d+\.\d+)", line)
                        if match and match.group(1).startswith(
                            subnet.rsplit(".", 2)[0]
                        ):
                            return match.group(1)
            else:
                result = subprocess.run(
                    ["ip", "route", "show", "default"],
                    capture_output=True,
                    text=True,
                    timeout=5,
                )
                match = re.search(r"via\s+(\d+\.\d+\.\d+\.\d+)", result.stdout)
                if match:
                    return match.group(1)
        except Exception as e:
            logger.debug(f"Could not detect gateway: {e}")

        # Fallback: assume .1 or .254
        for last_octet in ("1", "254"):
            candidate = f"{subnet}.{last_octet}"
            arp_mac = self._get_arp_mac(candidate)
            if arp_mac:
                return candidate
        return None

    # ─── Real MAC resolution (multi-strategy) ─────────────────

    def _get_real_mac(self, ip):
        """
        Try multiple methods to get the printer's *real* MAC address:
          1. HTTP web interface (JK-E02 and similar ethernet modules)
          2. SNMP query for ifPhysAddress
          3. ARP cache, but only if it differs from the gateway MAC
          4. None if all methods fail
        """
        # Strategy 1: HTTP web interface (most reliable for JK-E02 modules)
        http_mac = self._get_mac_http(ip)
        if http_mac:
            logger.info(f"  {ip}: got real MAC via HTTP web interface: {http_mac}")
            return http_mac

        # Strategy 2: SNMP
        snmp_mac = self._get_mac_snmp(ip)
        if snmp_mac:
            logger.info(f"  {ip}: got real MAC via SNMP: {snmp_mac}")
            return snmp_mac

        # Strategy 3: ARP with gateway filtering
        arp_mac = self._get_arp_mac(ip)
        if arp_mac and arp_mac != self._gateway_mac:
            logger.debug(f"  {ip}: got MAC via ARP (not gateway): {arp_mac}")
            return arp_mac

        if arp_mac and arp_mac == self._gateway_mac:
            logger.warning(
                f"  {ip}: ARP returned gateway MAC {arp_mac} — "
                f"printer is likely behind a secondary router. MAC will be unknown."
            )

        return None

    # ─── HTTP web interface MAC resolution ────────────────────

    def _get_mac_http(self, ip):
        """
        Many thermal printer ethernet modules (JK-E02, etc.) expose a web
        interface on port 80. The status page contains the real MAC address
        in decimal-separated format (e.g. "168-1-87-59-209-132").
        """
        sock = None
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(3)
            result = sock.connect_ex((ip, 80))
            if result != 0:
                return None

            sock.sendall(
                b"GET /port_stat.htm HTTP/1.0\r\nHost: "
                + ip.encode()
                + b"\r\nConnection: close\r\n\r\n"
            )

            data = b""
            while True:
                try:
                    chunk = sock.recv(4096)
                    if not chunk:
                        break
                    data += chunk
                    if len(data) > 16384:  # Safety limit
                        break
                except socket.timeout:
                    break

            if not data:
                return None

            html = data.decode("utf-8", errors="ignore")
            return self._parse_mac_from_html(html)

        except (socket.timeout, OSError, Exception) as e:
            logger.debug(f"  HTTP MAC lookup failed for {ip}: {e}")
            return None
        finally:
            if sock:
                try:
                    sock.close()
                except Exception:
                    pass

    def _parse_mac_from_html(self, html):
        """Extract MAC address from printer web interface HTML."""
        # Format 1: Standard hex-separated (AA:BB:CC:DD:EE:FF or AA-BB-CC-DD-EE-FF)
        hex_match = re.search(
            r"[Mm]ac.*?Address.*?([0-9a-fA-F]{2}[:-][0-9a-fA-F]{2}[:-]"
            r"[0-9a-fA-F]{2}[:-][0-9a-fA-F]{2}[:-][0-9a-fA-F]{2}[:-]"
            r"[0-9a-fA-F]{2})",
            html,
        )
        if hex_match:
            return hex_match.group(1).upper().replace("-", ":")

        # Format 2: Decimal-separated (JK-E02 modules: "168-1-87-59-209-132")
        dec_match = re.search(
            r"[Mm]ac.*?Address.*?(\d{1,3})-(\d{1,3})-(\d{1,3})"
            r"-(\d{1,3})-(\d{1,3})-(\d{1,3})",
            html,
            re.DOTALL,
        )
        if dec_match:
            octets = [int(dec_match.group(i)) for i in range(1, 7)]
            if all(0 <= o <= 255 for o in octets):
                return ":".join(f"{o:02X}" for o in octets)

        return None

    # ─── SNMP MAC resolution (raw UDP, no dependencies) ───────

    def _get_mac_snmp(self, ip, community=b"public"):
        """
        Send a raw SNMPv1 GET-NEXT request for the interface table
        (OID 1.3.6.1.2.1.2.2.1.6 = ifPhysAddress) and parse the
        first MAC-address response. No pysnmp needed.
        """
        try:
            oid = [1, 3, 6, 1, 2, 1, 2, 2, 1, 6]
            packet = self._build_snmp_getnext(community, oid)

            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.settimeout(2)
            sock.sendto(packet, (ip, 161))

            data, _ = sock.recvfrom(4096)
            sock.close()

            mac_bytes = self._parse_snmp_mac_response(data, oid)
            if mac_bytes and len(mac_bytes) == 6:
                mac_str = ":".join(f"{b:02X}" for b in mac_bytes)
                if mac_str != "00:00:00:00:00:00":
                    return mac_str
        except (socket.timeout, OSError):
            pass
        except Exception as e:
            logger.debug(f"  SNMP query to {ip} failed: {e}")
        return None

    @staticmethod
    def _encode_oid(oid):
        """BER-encode an OID value (without tag+length wrapper)."""
        if len(oid) < 2:
            return bytes([0])
        result = bytes([40 * oid[0] + oid[1]])
        for sub_id in oid[2:]:
            if sub_id < 0x80:
                result += bytes([sub_id])
            else:
                # multi-byte encoding for sub-identifiers >= 128
                pieces = []
                val = sub_id
                pieces.append(val & 0x7F)
                val >>= 7
                while val > 0:
                    pieces.append(0x80 | (val & 0x7F))
                    val >>= 7
                result += bytes(reversed(pieces))
        return result

    @staticmethod
    def _encode_length(length):
        """BER-encode a length field."""
        if length < 0x80:
            return bytes([length])
        elif length < 0x100:
            return bytes([0x81, length])
        else:
            return bytes([0x82, (length >> 8) & 0xFF, length & 0xFF])

    @staticmethod
    def _encode_tlv(tag, value):
        """Wrap value bytes in a TLV (tag-length-value) structure."""
        length = PrinterDiscovery._encode_length(len(value))
        return bytes([tag]) + length + value

    def _build_snmp_getnext(self, community, oid):
        """Build a raw SNMPv1 GET-NEXT request packet."""
        # Integer: version = 0 (SNMPv1)
        version = self._encode_tlv(0x02, b"\x00")
        # Octet string: community
        comm = self._encode_tlv(0x04, community)
        # OID
        oid_val = self._encode_oid(oid)
        oid_tlv = self._encode_tlv(0x06, oid_val)
        # NULL value
        null_val = self._encode_tlv(0x05, b"")
        # Varbind: SEQUENCE { oid, null }
        varbind = self._encode_tlv(0x30, oid_tlv + null_val)
        # VarbindList: SEQUENCE { varbind }
        varbind_list = self._encode_tlv(0x30, varbind)
        # Request-ID
        req_id = self._encode_tlv(0x02, b"\x01")
        # Error status
        error_status = self._encode_tlv(0x02, b"\x00")
        # Error index
        error_index = self._encode_tlv(0x02, b"\x00")
        # GET-NEXT PDU (tag 0xA1)
        pdu = self._encode_tlv(0xA1, req_id + error_status + error_index + varbind_list)
        # Full SNMP message
        return self._encode_tlv(0x30, version + comm + pdu)

    @staticmethod
    def _parse_snmp_mac_response(data, expected_oid_prefix=None):
        """
        Walk the BER-encoded SNMP response and extract the first
        OCTET STRING value that is 6 bytes long (a MAC address).

        Validates that the response OID is under the ifPhysAddress subtree
        to avoid false-positive matches on other 6-byte OCTET STRINGs.
        """
        try:
            # Simple heuristic: find OCTET STRING (tag 0x04) with length 6.
            # The ifPhysAddress OID prefix (1.3.6.1.2.1.2.2.1.6) encodes to
            # bytes [0x2B, 0x06, 0x01, 0x02, 0x01, 0x02, 0x02, 0x01, 0x06].
            # We verify this prefix appears before the MAC to reduce false positives.
            oid_prefix = bytes([0x2B, 0x06, 0x01, 0x02, 0x01, 0x02, 0x02, 0x01, 0x06])
            has_valid_oid = oid_prefix in data

            i = 0
            while i < len(data) - 7:
                # Look for OCTET STRING (tag 0x04) with length 6
                if data[i] == 0x04 and data[i + 1] == 0x06:
                    mac = data[i + 2 : i + 8]
                    # Only accept if we saw the ifPhysAddress OID in the response
                    if has_valid_oid:
                        return mac
                i += 1
        except Exception:
            pass
        return None

    # ─── ARP MAC resolution ───────────────────────────────────

    def _get_arp_mac(self, ip):
        """Get MAC address from ARP cache (ping first to populate)."""
        try:
            if _IS_WINDOWS:
                subprocess.run(
                    ["ping", "-n", "1", "-w", "1000", ip],
                    capture_output=True,
                    timeout=5,
                    **_SUBPROCESS_KWARGS,
                )
            else:
                subprocess.run(
                    ["ping", "-c", "1", "-W", "2", ip],
                    capture_output=True,
                    timeout=5,
                )
        except (subprocess.TimeoutExpired, FileNotFoundError):
            pass

        try:
            if _IS_WINDOWS:
                return self._get_mac_windows(ip)
            else:
                return self._get_mac_linux(ip)
        except Exception as e:
            logger.debug(f"Could not get ARP MAC for {ip}: {e}")
            return None

    def _get_mac_windows(self, ip):
        """Get MAC from Windows ARP cache."""
        try:
            result = subprocess.run(
                ["arp", "-a", ip],
                capture_output=True,
                text=True,
                timeout=5,
                **_SUBPROCESS_KWARGS,
            )
            for line in result.stdout.splitlines():
                if ip in line:
                    match = re.search(r"([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}", line)
                    if match:
                        return match.group(0).upper().replace("-", ":")
        except (subprocess.TimeoutExpired, FileNotFoundError):
            pass
        return None

    def _get_mac_linux(self, ip):
        """Get MAC from Linux ARP cache."""
        try:
            result = subprocess.run(
                ["ip", "neighbor", "show", ip],
                capture_output=True,
                text=True,
                timeout=5,
            )
            match = re.search(r"([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}", result.stdout)
            if match:
                return match.group(0).upper()
        except (subprocess.TimeoutExpired, FileNotFoundError):
            pass

        try:
            result = subprocess.run(
                ["arp", "-n", ip],
                capture_output=True,
                text=True,
                timeout=5,
            )
            for line in result.stdout.splitlines():
                if ip in line:
                    match = re.search(r"([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}", line)
                    if match:
                        return match.group(0).upper()
        except (subprocess.TimeoutExpired, FileNotFoundError):
            pass

        return None


    # ─── Streaming scan (yields printers as found) ──────────────

    def scan_streaming(self, subnet=None):
        """
        Generator that yields printers as they are discovered.
        Yields dicts: {"type": "network"|"usb", "ip": ..., "port": ..., "mac": ..., ...}
        Also yields status events: {"type": "status", "message": ...}
        """
        # Phase 1: USB printers (fast)
        yield {"type": "status", "phase": "usb", "message": "Scanning USB printers..."}
        for usb_printer in self.scan_usb():
            yield usb_printer

        # Phase 2: Network printers (slow, streamed)
        if subnet is None:
            subnet = self._detect_subnet()

        if not subnet:
            yield {"type": "status", "phase": "network", "message": "Could not detect network subnet"}
            return

        yield {"type": "status", "phase": "network", "message": f"Scanning {subnet}.0/24 on port {self.PRINTER_PORT}..."}

        self._gateway_mac = self._detect_gateway_mac(subnet)

        targets = [f"{subnet}.{i}" for i in range(1, 255)]

        with ThreadPoolExecutor(max_workers=self.MAX_WORKERS) as executor:
            futures = {
                executor.submit(self._check_port, ip, self.PRINTER_PORT): ip
                for ip in targets
            }
            for future in as_completed(futures):
                ip = futures[future]
                try:
                    is_open = future.result()
                    if is_open:
                        mac = self._get_real_mac(ip)
                        yield {
                            "type": "network",
                            "ip": ip,
                            "port": self.PRINTER_PORT,
                            "mac": mac,
                            "responsive": True,
                        }
                except Exception as e:
                    logger.debug(f"  Error scanning {ip}: {e}")

        yield {"type": "status", "phase": "done", "message": "Discovery complete"}

    # ─── USB printer discovery ─────────────────────────────────

    @staticmethod
    def scan_usb():
        """
        Discover USB printers using pyusb.
        Returns list of dicts with vendor_id, product_id, manufacturer, product, serial.
        Falls back gracefully if pyusb/libusb is not available.
        """
        try:
            import usb.core
            import usb.util
        except ImportError:
            logger.warning("pyusb not installed — USB printer discovery disabled")
            return []

        found = []
        try:
            devices = usb.core.find(find_all=True)
            if devices is None:
                return []

            for dev in devices:
                vendor_id = dev.idVendor
                product_id = dev.idProduct

                # Check if it's a known printer vendor
                is_known_vendor = vendor_id in KNOWN_PRINTER_VENDORS

                # Check USB class: 7 = Printer
                is_printer_class = False
                try:
                    for cfg in dev:
                        for intf in cfg:
                            if intf.bInterfaceClass == 7:
                                is_printer_class = True
                                break
                        if is_printer_class:
                            break
                except Exception:
                    pass

                if not is_known_vendor and not is_printer_class:
                    continue

                # Read device strings
                manufacturer = None
                product = None
                serial = None
                try:
                    manufacturer = usb.util.get_string(dev, dev.iManufacturer) if dev.iManufacturer else None
                except Exception:
                    pass
                try:
                    product = usb.util.get_string(dev, dev.iProduct) if dev.iProduct else None
                except Exception:
                    pass
                try:
                    serial = usb.util.get_string(dev, dev.iSerialNumber) if dev.iSerialNumber else None
                except Exception:
                    pass

                vendor_name = KNOWN_PRINTER_VENDORS.get(vendor_id)

                printer_info = {
                    "type": "usb",
                    "vendor_id": f"{vendor_id:#06x}",
                    "product_id": f"{product_id:#06x}",
                    "vendor_name": vendor_name or manufacturer or "Unknown",
                    "product": product or "USB Printer",
                    "serial": serial,
                    "responsive": True,
                }
                found.append(printer_info)
                logger.info(
                    f"  Found USB printer: {printer_info['vendor_name']} "
                    f"{printer_info['product']} ({vendor_id:#06x}:{product_id:#06x})"
                )

        except Exception as e:
            logger.warning(f"USB discovery error: {e}")

        return found


# ─── Standalone test ─────────────────────────────────────────
if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    d = PrinterDiscovery()

    print("=== USB Printers ===")
    usb_printers = d.scan_usb()
    if usb_printers:
        for p in usb_printers:
            print(f"  {p['vendor_name']} {p['product']} ({p['vendor_id']}:{p['product_id']})")
    else:
        print("  No USB printers found.")

    print("\n=== Network Printers ===")
    printers = d.scan()
    if printers:
        for ip, info in printers.items():
            print(f"  {ip}:{info['port']} (MAC: {info.get('mac', 'unknown')})")
    else:
        print("  No network printers found.")
