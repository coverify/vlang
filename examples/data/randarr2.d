// Copyright: Coverify Systems Technology 2013 - 2014
// License:   Distributed under the Boost Software License, Version 1.0.
//            (See accompanying file LICENSE_1_0.txt or copy at
//            http://www.boost.org/LICENSE_1_0.txt)
// Authors:   Puneet Goel <puneet@coverify.com>

import std.stdio;
import esdl.data.rand;
import esdl.data.obdd;
import esdl.data.bvec;

int FFFF = 20;

class Foo
{
  mixin Randomization;
  @rand!(8,8) byte[][] foo;
  void display() {
    import std.stdio;
    writeln(foo);
  }
  Constraint!q{
    foo.length > 4;
    foreach(i, ff; foo) {
      ff.length > 4;
      foreach(j, f; ff) {
	f == j + 2;
	f < 20;
      }
    }
  } aconst;
}

void main() {
  Foo foo = new Foo;
  for (size_t i=0; i!=2; ++i) {
    foo.randomize();
    foo.display();
  }
  import std.stdio;
  writeln("End of program");
}
