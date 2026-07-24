#pragma once

#include "syntax/analysis.hpp"
#include "syntax/c_api.h"

namespace soda::abi {

SODA_CPP_ANALYSIS_API Analyzer& unwrap_analyzer(soda_cpp_analyzer& analyzer);
SODA_CPP_ANALYSIS_API const Analysis& current_analysis(const soda_cpp_analyzer& analyzer);
SODA_CPP_ANALYSIS_API const Analysis& resync_analyzer(soda_cpp_analyzer& analyzer,
                                                      const DocumentSnapshot& snapshot);

} // namespace soda::abi
