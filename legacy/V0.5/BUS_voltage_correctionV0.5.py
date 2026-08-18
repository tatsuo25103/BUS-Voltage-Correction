import serial
import serial.tools.list_ports
import time
import sys
import logging
from contextlib import contextmanager
from collections import deque
import platform

# 設置日誌記錄器
logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

# 清除已有的處理器，防止日誌重複
if logger.hasHandlers():
    logger.handlers.clear()

# 創建控制台處理器
console_handler = logging.StreamHandler()
console_handler.setLevel(logging.INFO)

# 創建文件處理器，輸出到日誌文件
file_handler = logging.FileHandler('log_output.txt', mode='w', encoding='utf-8')
file_handler.setLevel(logging.INFO)

# 設置日誌格式
formatter = logging.Formatter('%(asctime)s - %(levelname)s - %(message)s')
console_handler.setFormatter(formatter)
file_handler.setFormatter(formatter)

# 將處理器添加到日誌器
logger.addHandler(console_handler)
logger.addHandler(file_handler)

# 防止日誌重複
logger.propagate = False

# 全域變數存儲找到的正確端口和總結信息
correct_ports = []
summary_info = {}

# 串口參數配置
BAUDRATE = 2400
TIMEOUT = 1
VOLTAGE_THRESHOLD = 5.0  # 電壓校正閾值，單位為V
MAX_CONSECUTIVE_ATTEMPTS = 5  # 最大連續嘗試次數
EXPECTED_CORRECTION = 0.5  # 每次預期校正的電壓值，單位為V
MIN_EFFECTIVE_RATIO = 0.6  # 最小有效修正比例
LOW_VOLTAGE_THRESHOLD = 50.0  # 低電壓閾值，單位為V
LOW_VOLTAGE_COUNT_LIMIT = 3  # 低電壓最大計數
VOLTAGE_DELTA_THRESHOLD = 0.3  # V/s

# 新增全域變數，計算總的無效修正次數
total_ineffective_corrections = 0

# 上下文管理器，用於管理串口的開啟和關閉
@contextmanager
def serial_port(port, baudrate=BAUDRATE, timeout=TIMEOUT):
    try:
        ser = serial.Serial(port=port, baudrate=baudrate, bytesize=8, stopbits=1,
                            parity=serial.PARITY_NONE, timeout=timeout)
        yield ser
    finally:
        ser.close()

# 讀取響應函數，確保數據讀取的完整性
def read_response(ser, expected_length, timeout=2):
    start_time = time.time()
    response = b''
    while len(response) < expected_length:
        if ser.in_waiting:
            response += ser.read(ser.in_waiting)
        if time.time() - start_time > timeout:
            logger.warning("Read response timeout.")
            break
    return response

# 發送指令函數
def send_command(ser, command, expected_response_length):
    ser.write(command.encode('utf-8'))
    response = read_response(ser, expected_response_length)
    return response

# 尋找並發送指令到正確的端口
def find_and_send_commands_to_correct_ports():
    global correct_ports
    ports_list = list(serial.tools.list_ports.comports())

    if len(ports_list) <= 0:
        logger.error("No serial ports found.")
        return

    expected_response = b'^D00517\xca\xec\r'
    logger.info("========== Scanning Serial Ports ==========")
    for comport in ports_list:
        try:
            with serial_port(comport.device) as ser:
                logger.info(f"Testing port {comport.device}...")
                command = '^P003PI\r\n'
                ser.write(command.encode('utf-8'))
                time.sleep(1)
                response = read_response(ser, len(expected_response))
                logger.info(f"Response from {comport.device}: {response}")

                if expected_response in response:
                    logger.info(f"*** Correct port found: {comport.device} ***")
                    correct_ports.append(comport.device)
                else:
                    logger.warning(f"Port {comport.device} did not return the correct response.")
        except serial.SerialException as e:
            logger.error(f"Serial exception on {comport.device}: {e}")
        except Exception as e:
            logger.error(f"Unexpected error on {comport.device}: {e}")

# 啟動 Inverter
def Boot_procedure():
    success_substring = b'^1\x0b\xc2\r'
    global correct_ports

    logger.info("========== Boot Procedure ==========")

    for port in correct_ports:
        try:
            with serial_port(port) as ser:
                new_command = '^S005LON1\r\n'
                logger.info(f"Sending command to {port}...")
                ser.write(new_command.encode('utf-8'))
                time.sleep(1)

                if ser.in_waiting > 0:
                    new_response = ser.read(ser.in_waiting)
                    logger.info(f"Response from {port} to command: {new_response}")
                else:
                    logger.warning(f"No response from {port}")
                    new_response = b''  # 防止後續判斷出錯

                if success_substring in new_response:
                    logger.info(f"{port} Set enable machine supply power to the loads succeeded.")
                    second_command = '^S006FT005\r\n'
                    ser.write(second_command.encode('utf-8'))
                    time.sleep(1)

                    if ser.in_waiting > 0:
                        second_response = ser.read(ser.in_waiting)
                        logger.info(f"Response from {port} to second command: {second_response}")
                    else:
                        logger.warning(f"No response from {port}")
                        second_response = b''  # 防止後續判斷出錯

                    if success_substring in second_response:
                        logger.info(f"{port} Set wait time for feed power succeeded.")
                    else:
                        logger.warning(f"{port} Set wait time for feed power failed.")
                    logger.info(f"Starting warm-up procedure for {port}...")
                    time.sleep(60)  # 等待60秒暖機
                    logger.info(f"Warm-up finished for {port}.")
                else:
                    logger.warning(f"{port} Set enable machine supply power to the loads failed.")
        except serial.SerialException as e:
            logger.error(f"Serial exception on {port}: {e}")
        except Exception as e:
            logger.error(f"Unexpected error on {port}: {e}")

# 解析電壓值函數
def parse_voltage_response(response, keys):
    try:
        values = response.strip().split(',')
        voltages = {}
        for key, index in keys.items():
            voltages[key] = int(values[index]) / 10.0  # 將讀取的值除以10.0，轉換為實際電壓值（單位V）
        return voltages
    except (IndexError, ValueError) as e:
        logger.error(f"Error parsing voltage response: {e}")
        return None

# 檢查電壓穩定性和低電壓監測
def check_voltage_stability(ser):
    voltage_keys = ['VR', 'VS', 'VT', 'VDSPP', 'VDSPN', 'VMCUP', 'VMCUN']
    stable_readings_required = 2
    stable_counts = {key: 0 for key in voltage_keys}
    voltage_history = {key: deque(maxlen=3) for key in voltage_keys}
    low_voltage_counts = {key: 0 for key in voltage_keys + ['Vref']}

    while True:
        # 讀取第一組電壓 VR VS VT
        ser.write(b'^P003GS\r\n')
        time.sleep(1)
        response_gs = ser.read(100).decode('utf-8', errors='ignore')
        logger.info(f"Response for ^P003GS: {response_gs}")
        gs_keys = {'VR': 7, 'VS': 8, 'VT': 9}
        voltages_gs = parse_voltage_response(response_gs, gs_keys)

        # 讀取第二組電壓 VDSP VMCU
        ser.write(b'^P005INGS\r\n')
        time.sleep(1)
        response_ings = ser.read(100).decode('utf-8', errors='ignore')
        logger.info(f"Response for ^P005INGS: {response_ings}")
        ings_keys = {'VDSPP': 9, 'VDSPN': 10, 'VMCUP': 11, 'VMCUN': 12}
        voltages_ings = parse_voltage_response(response_ings, ings_keys)

        if voltages_gs and voltages_ings:
            current_voltages = {**voltages_gs, **voltages_ings}
            # 計算 Vref
            voltage_VR = current_voltages['VR']
            voltage_VS = current_voltages['VS']
            voltage_VT = current_voltages['VT']
            Vref = max(voltage_VR, voltage_VS, voltage_VT) * 1.414
            current_voltages['Vref'] = Vref

            for key in voltage_keys:
                voltage_history[key].append(current_voltages[key])

                if len(voltage_history[key]) == 3 and max(voltage_history[key]) - min(voltage_history[key]) < 1.5:
                    stable_counts[key] += 1
                else:
                    stable_counts[key] = 0

            # 檢查低電壓情況
            for key in voltage_keys + ['Vref']:
                voltage_value = current_voltages[key] if key != 'Vref' else Vref
                if voltage_value < LOW_VOLTAGE_THRESHOLD:
                    low_voltage_counts[key] += 1
                    logger.warning(f"{key} voltage is below {LOW_VOLTAGE_THRESHOLD} V ({low_voltage_counts[key]}/{LOW_VOLTAGE_COUNT_LIMIT})")
                else:
                    low_voltage_counts[key] = 0  # 重置計數器

                if low_voltage_counts[key] >= LOW_VOLTAGE_COUNT_LIMIT:
                    logger.error(f"Error: {key} voltage below {LOW_VOLTAGE_THRESHOLD} V for {LOW_VOLTAGE_COUNT_LIMIT} consecutive times.")
                    logger.error("Please check the power supply or whether the device is powered on.")
                    sys.exit(1)  # 結束程序

            if all(count >= stable_readings_required for count in stable_counts.values()):
                logger.info("The bus voltage has stabilized.")
                return current_voltages
            else:
                logger.info("Waiting for the bus voltage to stabilize.")
        else:
            logger.warning("Failed to read voltage values.")

        time.sleep(2)

# 電壓變化率檢測
class VoltageSlopeError(Exception):
    """當電壓變化率超標時觸發"""
    def __init__(self, message="電壓變化異常，疑似外部干擾"):
        super().__init__(message)

def check_voltage_slope(ser):
    v1 = read_voltage(ser)
    time.sleep(1)
    v2 = read_voltage(ser)
    
    if abs(v2 - v1) > VOLTAGE_DELTA_THRESHOLD:
        logger.error(f"異常電壓變化率: {abs(v2-v1)}V/s")
        raise VoltageSlopeError()

# 讀取電壓值函數
def read_voltage(ser):
    ser.write(b'^P003GS\r\n')
    time.sleep(1)
    response_gs = ser.read(100).decode('utf-8', errors='ignore')
    logger.info(f"Response for ^P003GS: {response_gs}")
    gs_keys = {'VR': 7, 'VS': 8, 'VT': 9}
    voltages_gs = parse_voltage_response(response_gs, gs_keys)
    return voltages_gs['VR']

# 電壓校正函數（通用）
def voltage_correction(port, voltage_type, command_increase, command_decrease):
    global total_ineffective_corrections  # 引入全域變數
    correction_attempts = 0  # 修正次數
    correction_directions = []  # 修正方向列表
    ineffective_corrections = 0  # 無效修正計數

    initial_voltages = None
    previous_voltage = None  # 前一次的電壓值

    try:
        with serial_port(port) as ser:
            # 首先記錄初始電壓值
            initial_voltages = check_voltage_stability(ser)
            initial_voltage = initial_voltages[voltage_type]
            previous_voltage = initial_voltage
            logger.info(f"Initial {voltage_type} voltage: {initial_voltage} V")

            # 將初始電壓值記錄到總結信息中
            if port not in summary_info:
                summary_info[port] = {}
            summary_info[port][voltage_type] = {
                'initial_voltage': initial_voltage,
                'final_voltage': None,
                'actual_total_correction': 0.0,
                'correction_attempts': 0,
                'correction_directions': [],
                'status': 'Incomplete'
            }

            while True:
                # 檢查電壓穩定性
                final_voltages = check_voltage_stability(ser)
                current_voltage = final_voltages[voltage_type]
                voltage_VR = final_voltages['VR']
                voltage_VS = final_voltages['VS']
                voltage_VT = final_voltages['VT']
                # 計算參考電壓 Vref
                Vref = final_voltages['Vref']
                logger.info(f"Vref = {Vref:.2f} V")
                # 計算與參考電壓的差值
                delta_v = current_voltage - Vref
                logger.info(f"{voltage_type} - Vref = {delta_v:.2f} V")

                # 檢查電壓變化率
                check_voltage_slope(ser)

                # 計算實際總校正量
                actual_total_correction = current_voltage - initial_voltage
                logger.info(f"Actual total correction: {actual_total_correction:.2f} V")

                # 根據差值發送校正指令
                if delta_v > VOLTAGE_THRESHOLD:
                    ser.write(command_decrease.encode('utf-8'))
                    correction_direction = '-'
                elif delta_v < -VOLTAGE_THRESHOLD:
                    ser.write(command_increase.encode('utf-8'))
                    correction_direction = '+'
                else:
                    logger.info(f"{voltage_type} voltage correction completed.")
                    summary_info[port][voltage_type]['status'] = 'Success'
                    break  # 穩定後跳出循環

                correction_attempts += 1
                correction_directions.append(correction_direction)

                # 等待電壓穩定後再讀取電壓值
                new_voltages = check_voltage_stability(ser)
                new_voltage = new_voltages[voltage_type]

                # 計算實際的電壓變化量
                voltage_change = abs(new_voltage - previous_voltage)
                expected_change = EXPECTED_CORRECTION * MIN_EFFECTIVE_RATIO

                logger.info(f"Voltage change after correction: {voltage_change:.2f} V (Expected at least {expected_change:.2f} V)")

                # 檢查修正效果
                if voltage_change < expected_change:
                    ineffective_corrections += 1
                    total_ineffective_corrections += 1  # 增加總的無效修正計數
                    logger.warning(f"Ineffective correction detected ({ineffective_corrections}/{MAX_CONSECUTIVE_ATTEMPTS}). Total ineffective corrections: {total_ineffective_corrections}")
                else:
                    ineffective_corrections = 0  # 重置計數器

                if ineffective_corrections >= MAX_CONSECUTIVE_ATTEMPTS:
                    logger.error(f"Error: {voltage_type} voltage corrections ineffective after {MAX_CONSECUTIVE_ATTEMPTS} attempts, stopping correction.")
                    # 更新狀態為失敗，並結束函數
                    summary_info[port][voltage_type]['status'] = 'Failed'
                    break

                previous_voltage = new_voltage  # 更新前一次的電壓值

            # 記錄最終電壓值和校正信息
            summary_info[port][voltage_type]['final_voltage'] = current_voltage
            summary_info[port][voltage_type]['actual_total_correction'] = current_voltage - initial_voltage
            summary_info[port][voltage_type]['correction_attempts'] = correction_attempts
            summary_info[port][voltage_type]['correction_directions'] = correction_directions

            logger.info(f"Initial {voltage_type} voltage: {initial_voltage} V")
            logger.info(f"Final {voltage_type} voltage: {current_voltage} V")
            logger.info(f"Actual total correction: {current_voltage - initial_voltage} V")
            logger.info(f"Correction attempts: {correction_attempts}")
            logger.info(f"Correction directions: {correction_directions}")

        # 如果未成功，且達到最大嘗試次數，拋出異常以停止程序
        if summary_info[port][voltage_type]['status'] == 'Failed':
            raise Exception(f"{voltage_type} voltage correction failed after {MAX_CONSECUTIVE_ATTEMPTS} ineffective attempts.")

    except serial.SerialException as e:
        logger.error(f"Serial exception on {port}: {e}")
    except SystemExit:
        sys.exit(1)
    except Exception as e:
        logger.error(f"An error occurred during {voltage_type} correction on {port}: {e}")
        sys.exit(1)  # 結束程序

# DSP 正電壓校正
def dsp_p_voltage_correction(port):
    logger.info("========== DSP Positive Voltage Correction ==========")
    voltage_correction(port, 'VDSPP', 'BPVA+05\r\n', 'BPVA-05\r\n')

# DSP 負電壓校正
def dsp_n_voltage_correction(port):
    logger.info("========== DSP Negative Voltage Correction ==========")
    voltage_correction(port, 'VDSPN', 'BNVA+05\r\n', 'BNVA-05\r\n')

# MCU 正電壓校正
def MCU_p_voltage_correction(port):
    logger.info("========== MCU Positive Voltage Correction ==========")
    voltage_correction(port, 'VMCUP', 'SBPVA+05\r\n', 'SBPVA-05\r\n')

# MCU 負電壓校正
def MCU_n_voltage_correction(port):
    logger.info("========== MCU Negative Voltage Correction ==========")
    voltage_correction(port, 'VMCUN', 'SBNVA+05\r\n', 'SBNVA-05\r\n')

# 等待使用者按鍵退出
def wait_for_keypress():
    system = platform.system()
    if system == "Windows":
        import msvcrt
        print("按任意鍵退出...")
        msvcrt.getch()  # Windows 上等待任意鍵
    else:
        input("按 Enter 鍵退出...")  # 其他系統上按 Enter 鍵

# 輸出總結信息
def print_summary():
    logger.info("\n========== Summary ==========")
    logger.info(f"Total ineffective corrections: {total_ineffective_corrections}")
    for port, voltages in summary_info.items():
        logger.info(f"Port: {port}")
        for voltage_type, data in voltages.items():
            logger.info(f"  {voltage_type}:")
            logger.info(f"    Initial Voltage       : {data['initial_voltage']} V")
            logger.info(f"    Final Voltage         : {data['final_voltage']} V")
            logger.info(f"    Actual Total Correction: {data['actual_total_correction']} V")
            logger.info(f"    Correction Attempts   : {data['correction_attempts']}")
            logger.info(f"    Correction Directions : {data['correction_directions']}")
            logger.info(f"    Status                : {data['status']}")
    logger.info("========== End of Summary ==========")

def main():
    try:
        find_and_send_commands_to_correct_ports()
        Boot_procedure()
        for port in correct_ports:
            with serial_port(port) as ser:
                final_voltages = check_voltage_stability(ser)
                logger.info(f"Final voltages at {port}: {final_voltages}")
        for port in correct_ports:
            dsp_p_voltage_correction(port)
            dsp_n_voltage_correction(port)
            MCU_p_voltage_correction(port)
            MCU_n_voltage_correction(port)
            logger.info(f"{port}: BUS voltage calibration procedure completed.")
        print_summary()
    except KeyboardInterrupt:
        logger.warning("Program interrupted by user.")
    except SystemExit:
        logger.warning("Program exited due to low voltage condition or voltage correction failure.")
        print_summary()
        wait_for_keypress()  # 等待按鍵退出
        sys.exit(1)
    except Exception as e:
        logger.error(f"An error occurred: {e}")
        print_summary()
        wait_for_keypress()  # 等待按鍵退出
        sys.exit(1)
    finally:
        wait_for_keypress()  # 程式執行完畢後等待按鍵退出

if __name__ == '__main__':
    main()
