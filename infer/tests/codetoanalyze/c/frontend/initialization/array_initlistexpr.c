/*
 * Copyright (c) 2013 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

int init_const_array() {
  int z;
  int a[2][3] = {{z + 1, 2, 3}, {5, 6, 7}};
}

void init_variable_array(int len) {
  int x = 2 * len;
  int a[len + x + 1];
}
