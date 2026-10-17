#include <ACAN2517FD.h>
#include <SPI.h>

// NodeMCU ESP-32S v1.1 -> MCP2517FD module, confirmed on the user's hardware.
static constexpr uint8_t PIN_SCK = 18;
static constexpr uint8_t PIN_MOSI = 23;
static constexpr uint8_t PIN_MISO = 19;
static constexpr uint8_t PIN_CS = 5;
static constexpr uint8_t PIN_INT = 21;

static constexpr uint32_t SERIAL_BAUD = 1000000;
static constexpr uint16_t BUILD_NUMBER = 7;

ACAN2517FD can(PIN_CS, SPI, PIN_INT);

static bool canInitialized = false;
static bool canEnabled = true;
// This adapter is intended for SavvyCAN transmit as well as capture. It starts
// in active mode so opening the CP2102 serial port cannot silently disable TX.
static bool listenOnly = false;
static uint32_t canBitRate = 500000;
static bool canFdEnabled = true;
static uint32_t canDataBitRate = 2000000;

enum class ParserState : uint8_t {
  Idle,
  Command,
  SetCan,
  TxFrame,
  TxFdFrame,
  SetFd
};

static ParserState parserState = ParserState::Idle;
static uint8_t commandBuffer[72];
static uint8_t commandIndex = 0;
static uint8_t commandExpected = 0;

static void writeU32LE(uint8_t *buffer, const uint32_t value) {
  buffer[0] = static_cast<uint8_t>(value);
  buffer[1] = static_cast<uint8_t>(value >> 8);
  buffer[2] = static_cast<uint8_t>(value >> 16);
  buffer[3] = static_cast<uint8_t>(value >> 24);
}

static uint32_t readU32LE(const uint8_t *buffer) {
  return static_cast<uint32_t>(buffer[0]) |
         (static_cast<uint32_t>(buffer[1]) << 8) |
         (static_cast<uint32_t>(buffer[2]) << 16) |
         (static_cast<uint32_t>(buffer[3]) << 24);
}

static bool dataBitRateFactorFor(const uint32_t arbitrationBitRate,
                                 const uint32_t dataBitRate,
                                 DataBitRateFactor &factor) {
  if (arbitrationBitRate == 0 || dataBitRate % arbitrationBitRate != 0) return false;
  const uint32_t multiplier = dataBitRate / arbitrationBitRate;
  if (multiplier < 1 || multiplier > 10) return false;
  factor = static_cast<DataBitRateFactor>(multiplier);
  return true;
}

static bool configureCan(const uint32_t requestedBitRate,
                         const uint32_t requestedDataBitRate,
                         const bool requestedEnabled,
                         const bool requestedListenOnly,
                         const bool requestedFdEnabled) {
  const uint32_t arbitrationBitRate = constrain(requestedBitRate, 10000UL, 1000000UL);
  DataBitRateFactor dataBitRateFactor = DataBitRateFactor::x1;
  if (!dataBitRateFactorFor(arbitrationBitRate, requestedDataBitRate,
                            dataBitRateFactor)) return false;

  ACAN2517FDSettings settings(
      ACAN2517FDSettings::OSC_20MHz,
      arbitrationBitRate,
      dataBitRateFactor);
  if (settings.CANBitSettingConsistency() != 0) return false;

  if (canInitialized) {
    can.end();
    canInitialized = false;
  }

  canBitRate = arbitrationBitRate;
  canDataBitRate = requestedDataBitRate;
  canEnabled = requestedEnabled;
  listenOnly = requestedListenOnly;
  canFdEnabled = requestedFdEnabled;
  if (!canEnabled) return true;

  settings.mRequestedMode = listenOnly
      ? ACAN2517FDSettings::ListenOnly
      : (canFdEnabled ? ACAN2517FDSettings::NormalFD
                      : ACAN2517FDSettings::Normal20B);
  settings.mDriverReceiveFIFOSize = 64;
  settings.mDriverTransmitFIFOSize = 32;

  const uint32_t errorCode = can.begin(settings, [] { can.isr(); });
  canInitialized = errorCode == 0;
  return canInitialized;
}

static void sendTimeSync() {
  uint8_t response[6] = {0xF1, 0x01, 0, 0, 0, 0};
  writeU32LE(response + 2, micros());
  Serial.write(response, sizeof(response));
}

static void sendCanParameters() {
  uint8_t response[12] = {0xF1, 0x06, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
  response[2] = (canEnabled ? 1 : 0) | (listenOnly ? 0x10 : 0);
  writeU32LE(response + 3, canBitRate);
  // Bytes 7..11 describe the absent second CAN channel and stay zero.
  Serial.write(response, sizeof(response));
}

static void sendDeviceInfo() {
  const uint8_t response[8] = {
      0xF1, 0x07,
      static_cast<uint8_t>(BUILD_NUMBER),
      static_cast<uint8_t>(BUILD_NUMBER >> 8),
      1, 0, 0, 0};
  Serial.write(response, sizeof(response));
}

static void sendKeepAlive() {
  const uint8_t response[4] = {0xF1, 0x09, 0xDE, 0xAD};
  Serial.write(response, sizeof(response));
}

static void sendBusCount() {
  const uint8_t response[3] = {0xF1, 0x0C, 1};
  Serial.write(response, sizeof(response));
}

static void sendFdSettings() {
  uint8_t response[11] = {0xF1, 0x16, 1, 1, 0, 0, 0, 0, 0, 0, 0};
  // Version 1, one bus. Flags: enabled, supported, BRS supported, ISO FD.
  response[5] = (canFdEnabled ? 0x01 : 0x00) | 0x02 | 0x04 | 0x08;
  writeU32LE(response + 6, canDataBitRate);
  Serial.write(response, sizeof(response));
}

static void sendControllerStatus() {
  uint8_t response[17] = {0xF1, 0x17, 1, 0, 0, 0, 0, 0, 0,
                          0, 0, 0, 0, 0, 0, 0, 0};
  // Version 1, bus 0. Low flags: initialized, enabled, FD, listen-only.
  // Bits 4..6 contain the MCP2517FD operation mode.
  response[4] = (canInitialized ? 0x01 : 0x00) |
                (canEnabled ? 0x02 : 0x00) |
                (canFdEnabled ? 0x04 : 0x00) |
                (listenOnly ? 0x08 : 0x00);
  if (canInitialized) {
    response[4] |= (static_cast<uint8_t>(can.currentOperationMode()) & 0x07) << 4;
    // Raw MCP2517FD CiTREC, CiBDIAG0 and CiBDIAG1 registers. Keeping the raw
    // values makes the extension useful without discarding diagnostic bits.
    writeU32LE(response + 5, can.errorCounters());
    writeU32LE(response + 9, can.diagInfos(0));
    writeU32LE(response + 13, can.diagInfos(1));
  }
  Serial.write(response, sizeof(response));
}

static void sendReceivedFrame(const CANFDMessage &frame) {
  if (frame.type == CANFDMessage::CAN_REMOTE || frame.len > 64) return;

  const bool isClassic = frame.type == CANFDMessage::CAN_DATA && frame.len <= 8;
  const bool isFd = frame.type == CANFDMessage::CANFD_NO_BIT_RATE_SWITCH ||
                    frame.type == CANFDMessage::CANFD_WITH_BIT_RATE_SWITCH;
  if (!isClassic && !isFd) return;

  uint8_t packet[78];
  packet[0] = 0xF1;
  packet[1] = isClassic ? 0x00 : 0x14;
  writeU32LE(packet + 2, micros());
  uint32_t id = frame.id;
  if (frame.ext) id |= 0x80000000UL;
  writeU32LE(packet + 6, id);

  if (isClassic) {
    packet[10] = frame.len;  // Bus 0 occupies the high nibble.
    memcpy(packet + 11, frame.data, frame.len);
    packet[11 + frame.len] = 0;  // Legacy GVRET checksum is ignored by SavvyCAN.
    Serial.write(packet, 12 + frame.len);
  } else {
    packet[10] = frame.len & 0x7F;
    if (frame.type == CANFDMessage::CANFD_WITH_BIT_RATE_SWITCH) packet[10] |= 0x80;
    packet[11] = 0;  // Bus number is a separate byte for FD packets.
    memcpy(packet + 12, frame.data, frame.len);
    packet[12 + frame.len] = 0;
    Serial.write(packet, 13 + frame.len);
  }
}

static void transmitClassicFrame(const uint8_t *packet) {
  if (!canInitialized || listenOnly) return;
  const uint32_t encodedId = readU32LE(packet);
  const uint8_t bus = packet[4] & 0x03;
  const uint8_t length = min<uint8_t>(packet[5], 8);
  if (bus != 0) return;

  CANFDMessage frame;
  frame.id = encodedId & 0x1FFFFFFFUL;
  frame.ext = (encodedId & 0x80000000UL) != 0;
  frame.type = CANFDMessage::CAN_DATA;
  frame.len = length;
  memcpy(frame.data, packet + 6, length);
  can.tryToSend(frame);
}

static bool isValidFdLength(const uint8_t length) {
  return length <= 8 || length == 12 || length == 16 || length == 20 ||
         length == 24 || length == 32 || length == 48 || length == 64;
}

// Host-to-adapter FD packet (command 0x14):
// ID[4] little-endian, length/BRS, bus, data[0..64], checksum.
// ID bit 31 selects an extended identifier; length bit 7 selects BRS.
static void transmitFdFrame(const uint8_t *packet) {
  if (!canInitialized || listenOnly || !canFdEnabled) return;

  const uint32_t encodedId = readU32LE(packet);
  const uint8_t length = packet[4] & 0x7F;
  const bool bitRateSwitch = (packet[4] & 0x80) != 0;
  const uint8_t bus = packet[5];
  if (bus != 0 || !isValidFdLength(length)) return;

  CANFDMessage frame;
  frame.id = encodedId & 0x1FFFFFFFUL;
  frame.ext = (encodedId & 0x80000000UL) != 0;
  frame.type = bitRateSwitch
      ? CANFDMessage::CANFD_WITH_BIT_RATE_SWITCH
      : CANFDMessage::CANFD_NO_BIT_RATE_SWITCH;
  frame.len = length;
  memcpy(frame.data, packet + 6, length);
  can.tryToSend(frame);
}

static void applyCanSetup(const uint8_t *packet) {
  const uint32_t encoded = readU32LE(packet);
  uint32_t requestedBitRate = encoded & 0x000FFFFFUL;
  bool requestedEnabled = requestedBitRate != 0;
  bool requestedListenOnly = false;

  if ((encoded & 0x80000000UL) != 0) {
    requestedEnabled = (encoded & 0x40000000UL) != 0;
    requestedListenOnly = (encoded & 0x20000000UL) != 0;
  }
  if (requestedBitRate == 0) requestedBitRate = canBitRate;
  DataBitRateFactor currentFactor = DataBitRateFactor::x1;
  if (!dataBitRateFactorFor(canBitRate, canDataBitRate, currentFactor)) {
    currentFactor = DataBitRateFactor::x1;
  }
  const uint32_t requestedDataBitRate =
      requestedBitRate * static_cast<uint8_t>(currentFactor);
  configureCan(requestedBitRate, requestedDataBitRate, requestedEnabled,
               requestedListenOnly, canFdEnabled);
}

static void applyFdSetup(const uint8_t *packet) {
  const uint8_t bus = packet[0];
  const bool requestedFdEnabled = (packet[1] & 0x01) != 0;
  const uint32_t requestedDataBitRate = readU32LE(packet + 2);
  if (bus == 0) {
    configureCan(canBitRate, requestedDataBitRate, canEnabled, listenOnly,
                 requestedFdEnabled);
  }
  sendFdSettings();
}

static void startCommand(const uint8_t command) {
  commandIndex = 0;
  switch (command) {
    case 0x00:  // Send classic CAN frame.
      parserState = ParserState::TxFrame;
      commandExpected = 6;  // ID, bus and length; data/checksum extend this later.
      break;
    case 0x14:  // Send CAN FD frame.
      parserState = ParserState::TxFdFrame;
      commandExpected = 6;  // ID, length/BRS and bus; data/checksum follow.
      break;
    case 0x01:
      sendTimeSync();
      parserState = ParserState::Idle;
      break;
    case 0x05:  // Two four-byte bus settings plus checksum.
      parserState = ParserState::SetCan;
      commandExpected = 9;
      break;
    case 0x06:
      sendCanParameters();
      parserState = ParserState::Idle;
      break;
    case 0x07:
      sendDeviceInfo();
      parserState = ParserState::Idle;
      break;
    case 0x09:
      sendKeepAlive();
      parserState = ParserState::Idle;
      break;
    case 0x0C:
      sendBusCount();
      parserState = ParserState::Idle;
      break;
    case 0x15:  // Configure CAN FD for one bus.
      parserState = ParserState::SetFd;
      commandExpected = 7;  // Bus, flags, data rate and checksum.
      break;
    case 0x16:  // Read CAN FD capabilities and settings.
      sendFdSettings();
      parserState = ParserState::Idle;
      break;
    case 0x17:  // Read MCP2517FD error counters and diagnostics.
      sendControllerStatus();
      parserState = ParserState::Idle;
      break;
    default:
      parserState = ParserState::Idle;
      break;
  }
}

static void processSerialByte(const uint8_t value) {
  switch (parserState) {
    case ParserState::Idle:
      if (value == 0xF1) parserState = ParserState::Command;
      // 0xE7 switches legacy GVRET devices into binary mode. This firmware is
      // binary-only, so no state change is required.
      break;

    case ParserState::Command:
      startCommand(value);
      break;

    case ParserState::SetCan:
      commandBuffer[commandIndex++] = value;
      if (commandIndex >= commandExpected) {
        applyCanSetup(commandBuffer);
        parserState = ParserState::Idle;
      }
      break;

    case ParserState::TxFrame:
      commandBuffer[commandIndex++] = value;
      if (commandIndex == 6) {
        commandExpected = 7 + min<uint8_t>(commandBuffer[5], 8);  // Header + data + checksum.
      }
      if (commandIndex >= commandExpected) {
        transmitClassicFrame(commandBuffer);
        parserState = ParserState::Idle;
      }
      break;

    case ParserState::TxFdFrame:
      commandBuffer[commandIndex++] = value;
      if (commandIndex == 6) {
        const uint8_t length = commandBuffer[4] & 0x7F;
        if (length > 64) {
          parserState = ParserState::Idle;
          break;
        }
        commandExpected = 7 + length;  // Header + data + checksum.
      }
      if (parserState == ParserState::TxFdFrame && commandIndex >= commandExpected) {
        transmitFdFrame(commandBuffer);
        parserState = ParserState::Idle;
      }
      break;

    case ParserState::SetFd:
      commandBuffer[commandIndex++] = value;
      if (commandIndex >= commandExpected) {
        applyFdSetup(commandBuffer);
        parserState = ParserState::Idle;
      }
      break;
  }
}

void setup() {
  Serial.begin(SERIAL_BAUD);
  pinMode(PIN_CS, OUTPUT);
  digitalWrite(PIN_CS, HIGH);
  pinMode(PIN_INT, INPUT_PULLUP);
  SPI.begin(PIN_SCK, PIN_MISO, PIN_MOSI);
  configureCan(canBitRate, canDataBitRate, canEnabled, listenOnly, canFdEnabled);
}

void loop() {
  while (Serial.available() > 0) {
    processSerialByte(static_cast<uint8_t>(Serial.read()));
  }

  if (canInitialized) {
    CANFDMessage frame;
    while (can.receive(frame)) {
      sendReceivedFrame(frame);
    }
  }
}
