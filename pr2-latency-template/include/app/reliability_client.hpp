#pragma once

namespace app {
class Options;

// Отдельный сценарий клиента поверх того же UDP-транспорта и протокола.
int RunReliability(const Options& options);
}
