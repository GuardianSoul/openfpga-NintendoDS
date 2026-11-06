cmake_minimum_required(VERSION 3.16)
project(melonds_census CXX C)

set(MELONDS_DIR "" CACHE PATH "Patched melonDS source tree")
set(BUILD_QT_SDL OFF CACHE BOOL "" FORCE)
set(ENABLE_JIT OFF CACHE BOOL "" FORCE)
set(ENABLE_OGLRENDERER OFF CACHE BOOL "" FORCE)
set(ENABLE_GDBSTUB OFF CACHE BOOL "" FORCE)
set(ENABLE_LTO_RELEASE OFF CACHE BOOL "" FORCE)
# DS-verified rules not yet in the RTL (ds-rules.patch): on in the census build
add_compile_definitions(DS_RULE_TOON DS_RULE_HILITE DS_RULE_LIN17 DS_RULE_LINZ DS_RULE_YPERSP DS_RULE_XPERSP16 DS_RULE_AACOV DS_RULE_AAYCOV DS_RULE_TEXRND DS_RULE_ZFACE DS_RULE_TEX4X4 DS_RULE_SPU_CAPTURE DS_RULE_SPU_CAP8 DS_RULE_STRIPCLIP DS_RULE_FARREJ DS_RULE_CLIPRED DS_RULE_GXTIME DS_RULE_TMRFREE DS_RULE_TMRCNT)
add_subdirectory(${MELONDS_DIR} melonDS)

add_executable(census census.cpp export_state.cpp platform.cpp)
target_compile_features(census PRIVATE cxx_std_17)
target_link_libraries(census PRIVATE core)
target_include_directories(census PRIVATE ${CMAKE_SOURCE_DIR}/../../sim/gpu2d ${CMAKE_SOURCE_DIR}/../../sim/sound)

add_executable(gx2scene gx2scene.cpp platform.cpp)
target_compile_features(gx2scene PRIVATE cxx_std_17)
target_link_libraries(gx2scene PRIVATE core)

add_executable(gxstats gxstats.cpp platform.cpp)
target_compile_features(gxstats PRIVATE cxx_std_17)
target_link_libraries(gxstats PRIVATE core)
