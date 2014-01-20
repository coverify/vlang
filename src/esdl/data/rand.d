// Written in the D programming language.

// Copyright: Coverify Systems Technology 2012 - 2014
// License:   Distributed under the Boost Software License, Version 1.0.
//            (See accompanying file LICENSE_1_0.txt or copy at
//            http://www.boost.org/LICENSE_1_0.txt)
// Authors:   Puneet Goel <puneet@coverify.com>

module esdl.data.rand;

import esdl.data.obdd;

import std.ascii: whitespace;
import std.traits: isSomeString;
import std.traits: isIntegral;
import esdl.data.bvec: isBitVector;
import std.algorithm : min, max;
import esdl.data.bstr;

import std.exception: enforce;

template rand(N...) {
  static if(CheckRandParams!N) {
    struct rand
    {
      enum maxBounds = N;
      // this(int N) {
      // }
    }
  }
}

// Make sure that all the parameters are of type size_t
template CheckRandParams(N...) {
  static if(N.length > 0) {
    import std.traits;
    static if(!is(typeof(N[0]) == bool) && // do not confuse bool as size_t
	      is(typeof(N[0]) : size_t)) {
      static assert(N[0] != 0, "Can not have arrays with size 0");
      static assert(N[0] > 0, "Can not have arrays with negative size");
      enum bool CheckRecurse = CheckRandParams!(N[1..$]);
      enum bool CheckRandParams = CheckRecurse;
    }
    else {
      static assert(false, "Only positive integral values are allowed as array dimensions");
      enum bool CheckRandParams = false;
    }
  }
  else {
    enum bool CheckRandParams = true;
  }
}

abstract class _ESDL__ConstraintBase
{
  this(ConstraintEngine eng, string name, uint index) {
    _cstEng = eng;
    _name = name;
    _index = index;
  }

  protected bool _enabled = true;
  protected ConstraintEngine _cstEng;
  protected string _name;
  // index in the constraint Database
  protected uint _index;

  public bool isEnabled() {
    return _enabled;
  }

  public void enable() {
    _enabled = false;
  }

  public void disable() {
    _enabled = true;
  }

  public bdd getConstraintBDD() {
    return _cstEng._buddy.one();
  }

  public string name() {
    return _name;
  }

  abstract public CstBlock getCstExpr();

  public void applyMaxArrayLengthCst(ref bdd solveBDD, CstStage stage) {}
}

abstract class Constraint (string C) : _ESDL__ConstraintBase
{
  this(ConstraintEngine eng, string name, uint index) {
    super(eng, name, index);
  }

  static immutable string _constraint = C;
  // enum _parseTree = CstGrammar.parse(_constraint);
  // pragma(msg, _parseTree.capture);

  // Called by mixin to create functions out of parsed constraints
  static char[] constraintFoo(string CST) {
    import esdl.data.cstx;
    return translate(CST);
  }

  debug(CONSTRAINTS) {
    pragma(msg, constraintFoo(C));
  }
};

class Constraint(string C, string NAME, T, S): Constraint!C
{
  T _outer;
  S _outerD;

  this(T t, S s, ConstraintEngine eng, string name, uint index) {
    super(eng, name, index);
    _outer = t;
    _outerD = s;
  }
  // This mixin writes out the bdd functions after parsing the
  // constraint string at compile time
  static if(NAME == "_esdl__lengthConstraint") {
    override public void applyMaxArrayLengthCst(ref bdd solveBDD,
						CstStage stage) {
      _esdl__initLengthCsts(_outerD, solveBDD, stage);
    }

    override public CstBlock getCstExpr() {
      auto cstExpr = new CstBlock;
      return cstExpr;
    }
  }
  else {
    mixin(constraintFoo(C));
  }
}

struct RandGen
{
  import std.random;
  import esdl.data.bvec;

  private Random _gen;

  private bvec!32 _bv;

  private ubyte _bi = 32;

  this(uint _seed) {
    _gen = Random(_seed);
  }

  void seed(uint _seed) {
    _gen.seed(_seed);
  }

  public bool flip() {
    if(_bi > 31) {
      _bi = 0;
      _bv = uniform!"[]"(0, uint.max, _gen);
    }
    return cast(bool) _bv[_bi++];
  }

  public double get() {
    return uniform(0.0, 1.0, _gen);
  }

  @property public T gen(T)() {
    static if(isIntegral!T) {
      T result = uniform!(T)(_gen);
      return result;
    }
    else static if(isBitVector!T) {
	T result;
	result.randomize(_gen);
	return result;
      }
      else {
	static assert(false);
      }
  }

  @property public auto gen(T1, T2)(T1 a, T2 b)
    if(isIntegral!T1 && isIntegral!T2) {
      return uniform(a, b, _gen);
    }
}

// Later we will use freelist to allocate CstStage
class CstStage {
  int _id = -1;
  // List of randomized variables associated with this stage. Each
  // variable can be associated with only one stage
  CstVecPrim[] _randVecs;
  CstBddExpr[] _bddExprs;
  CstVecLoopVar[] _loopVars;
  CstVecRandArr[] _lengthVars;

  public void id(uint i) {
    _id = i;
  }

  public uint id() {
    return _id;
  }

  public bool solved() {
    if(_id != -1) return true;
    else return false;
  }
}

public class ConstraintEngine {
  // Keep a list of constraints in the class
  _ESDL__ConstraintBase cstList[];
  _ESDL__ConstraintBase arrayMaxLengthCst;
  // ParseTree parseList[];
  RandGen _rgen;
  Buddy _buddy;
  
  BddDomain[] _domains;

  this(uint seed) {
    _rgen.seed(seed);
  }

  public void markCstStageLoops(CstBddExpr expr) {
    auto vecs = expr.getPrims();
    foreach(ref vec; vecs) {
      if(vec !is null) {
	auto stage = vec.stage();
	if(stage !is null) {
	  stage._loopVars ~= expr.loopVars;
	}
      }
    }
  }

  // list of constraint statements to solve at a given stage
  public void addCstStage(CstBddExpr expr, ref CstStage[] cstStages) {
    // uint stage = cast(uint) _cstStages.length;
    auto vecs = expr.getPrims();
    CstStage stage;
    foreach(ref vec; vecs) {
      if(vec !is null) {
	if(vec.stage() is null) {
	  if(stage is null) {
	    stage = new CstStage();	    
	    cstStages ~= stage;
	  }
	  vec.stage = stage;
	  stage._randVecs ~= vec;
	  // cstStages[stage]._randVecs ~= vec;
	}
	if(stage !is vec.stage()) { // need to merge stages
	  mergeCstStages(stage, vec.stage(), cstStages);
	  stage = vec.stage();
	}
      }
    }
    stage._bddExprs ~= expr;
    stage._lengthVars ~= expr.lengthVars();
  }

  public void mergeCstStages(CstStage fromStage, CstStage toStage,
			     ref CstStage[] cstStages) {
    if(fromStage is null) {
      // fromStage has not been created yet
      return;
    }
    foreach(ref vec; fromStage._randVecs) {
      vec.stage = toStage;
    }
    toStage._randVecs ~= fromStage._randVecs;
    if(cstStages[$-1] is fromStage) {
      cstStages.length -= 1;
    }
    else {
      cstStages[$-1] = null;
    }
  }

  void initDomains() {
    uint domIndex = 0;
    int[] domList;
    auto cstStmts = new CstBlock();	// start empty

    // take all the constraints -- even if disabled
    foreach(ref _ESDL__ConstraintBase cst; cstList) {
      cstStmts ~= cst.getCstExpr();
    }

    foreach(stmt; cstStmts._exprs) {
      foreach(vec; stmt.getPrims()) {
	if(vec.domIndex == uint.max) {
	  vec.domIndex = domIndex++;
	  domList ~= vec.bitcount;
	}
      }
    }

    import std.stdio;
    writeln("Total domains: ", domIndex);

    _buddy.clearAllDomains();
    _domains = _buddy.extDomain(domList);

  }

  void solve() {
    // import std.stdio;
    // writeln("Solving BDD for number of contraints = ", cstList.length);

    if(_domains.length is 0) {
      initDomains();
    }

    auto cstStmts = new CstBlock();	// start empty

    CstStage[] cstStages;

    foreach(ref _ESDL__ConstraintBase cst; cstList) {
      if(cst.isEnabled()) {
	cstStmts ~= cst.getCstExpr();
      }
    }

    auto cstExprs = cstStmts._exprs;

    foreach(expr; cstExprs) {
      if(expr.loopVars().length is 0) {
	addCstStage(expr, cstStages);
      }
    }

    foreach(expr; cstExprs) {
      if(expr.loopVars().length !is 0) {
	// We want to mark the stages that are dependent on a
	// loopVar -- so that when these loops get resolved, we are
	// able to factor in more constraints into these stages and
	// then resolve
	markCstStageLoops(expr);
      }
    }

    auto usExprs = cstExprs;	// unstaged Expressions -- all
    auto urStages = cstStages;	// unresolved stages -- all

    // First we solve the constraint groups that are responsible for
    // setting the length of the rand!n dynamic arrays. After each
    // such constraint group is resolved, we go back and expand the
    // constraint expressions that depend on the LOOP Variables.

    // Once we have unrolled all the LOOPS, we go ahead and resolve
    // everything that remains.
    
    int stageIdx=0;
    bool allArraysResolved=false;

    while(usExprs.length > 0 || urStages.length > 0) {

      cstExprs = usExprs;
      usExprs.length = 0;
      cstStages = urStages;
      urStages.length = 0;

      foreach(stage; cstStages) {
	if(stage !is null &&
	   stage._randVecs.length !is 0) {
	  if(allArraysResolved) {
	    solveStage(stage, stageIdx);
	  }
	  // resolve allArraysResolved
	  else {
	    allArraysResolved = true;
	    if(stage._loopVars.length is 0 &&
	       stage._lengthVars.length !is 0) {
	      solveStage(stage, stageIdx);
	      allArraysResolved = false;
	    }
	    else {
	      urStages ~= stage;
	      // usExprs ~= stage; 
	    }
	  }
	}
      }
    }
  }

  void solveStage(CstStage stage, ref int stageIdx) {
    import std.conv;
    // initialize the bdd vectors
    foreach(vec; stage._randVecs) {
      if(vec.stage is stage && vec.bddvec is null) {
	vec.bddvec = _buddy.buildVec(_domains[vec.domIndex], vec.signed);
      }
    }

    // make the bdd tree
    auto exprs = stage._bddExprs;

    bdd solveBDD = _buddy.one();
    foreach(expr; exprs) {
      solveBDD &= expr.getBDD(stage, _buddy);
    }

    // The idea is that we apply the max length constraint only if
    // there is another constraint on the lenght. If there is no
    // other constraint, then the array is taken care of later at
    // the time of setting the non-constrained random variables

    // FIXME -- this behavior needs to change. Consider the
    // scenario where the length is not constrained but the
    // elements are
    arrayMaxLengthCst.applyMaxArrayLengthCst(solveBDD, stage);

    double[uint] bddDist;
    solveBDD.satDist(bddDist);

    auto solution = solveBDD.randSatOne(this._rgen.get(),
					bddDist);

    auto solVecs = solution.toVector();
    enforce(solVecs.length == 1,
	    "Expecting exactly one solutions here; got: " ~
	    to!string(solVecs.length));

    auto bits = solVecs[0];

    foreach(vec; stage._randVecs) {
      vec.value = 0;	// init
      foreach(uint i, ref j; solveBDD.getIndices(vec.domIndex)) {
	if(bits[j] == 1) {
	  vec.value = vec.value + (1L << i);
	}
	if(bits[j] == -1) {
	  vec.value = vec.value + ((cast(ulong) _rgen.flip()) << i);
	}
      }
      // vec.bddvec = null;
    }
    if(stage !is null) {stage.id(stageIdx);};
    ++stageIdx;
  }

  void printSolution() {
    // import std.stdio;
    // writeln("There are solutions: ", _theBDD.satCount());
    // writeln("Distribution: ", dist);
    // auto randSol = _theBDD.randSat(randGen, dist);
    // auto solution = _theBDD.fullSatOne();
    // solution.printSetWith_Domains();
  }
}


template isRandomizable(T) {	// check if T is Randomizable
  import std.traits;
  import std.range;
  import esdl.data.bvec;
  static if(isArray!T) {
    enum bool isRandomizable = isRandomizable!(ElementType!T);
  }
  else
    static if(isIntegral!T || isBitVector!T) {
      enum bool isRandomizable = true;
    }
    else {
      bool isRandomizable = false;
    }
}

// Need to change this function to return only the count of @rand members
public size_t _esdl__countRands(size_t I=0, size_t C=0, T)(T t)
  if(is(T unused: RandomizableIntf)) {
    static if(I == t.tupleof.length) {
      static if(is(T B == super)
		&& is(B[0] : RandomizableIntf)
		&& is(B[0] == class)) {
	B[0] b = t;
	return _esdl__countRands!(0, C)(b);
      }
      else {
	return C;
      }
    }
    else {
      import std.traits;
      import std.range;
      // check for the integral members
      alias typeof(t.tupleof[I]) L;
      static if((isIntegral!L || isBitVector!L) &&
		findRandElemAttr!(I, t) != -1) {
	return _esdl__countRands!(I+1, C+1)(t);
      }
      else static if(isStaticArray!L && (isIntegral!(ElementType!L) ||
					 isBitVector!(ElementType!L)) &&
		     findRandElemAttr!(I, t) != -1) {
	  return _esdl__countRands!(I+1, C+1)(t);
	}
      else static if(isDynamicArray!L && (isIntegral!(ElementType!L) ||
					  isBitVector!(ElementType!L)) &&
		     findRandArrayAttr!(I, t) != -1) {
	  return _esdl__countRands!(I+1, C+1)(t);
	}
      // ToDo -- Fixme -- Add code for array randomization here
	else {
	  return _esdl__countRands!(I+1, C)(t);
	}
    }
  }

private template _esdl__randVar(string var) {
  import std.string;
  enum I = _esdl__randIndexof!(var);
  static if(I == -1) {
    enum string prefix = var;
    enum string suffix = "";
  }
  else {
    enum string prefix = var[0..I];
    enum string suffix = var[I..$];
  }
}

private template _esdl__randIndexof(string var, int index=0) {
  static if(index == var.length) {
    enum _esdl__randIndexof = -1;
  }
  else static if(var[index] == '.' ||
		 var[index] == '[' ||
		 var[index] == '(') {
      enum _esdl__randIndexof = index;
    }
    else {
      enum _esdl__randIndexof = _esdl__randIndexof!(var, index+1);
    }
}

interface RandomizableIntf
{
  static final string _esdl__randomizable() {
    return q{

      public CstVecPrim[] _cstRands;

      public ConstraintEngine _esdl__cstEng;
      public uint _esdl__randSeed;

      public void seedRandom (int seed) {
	_esdl__randSeed = seed;
	if (_esdl__cstEng !is null) {
	  _esdl__cstEng._rgen.seed(seed);
	}
      }
      alias seedRandom srandom;	// for sake of SV like names

      public ConstraintEngine getCstEngine() {
	return _esdl__cstEng;
      }

      void pre_randomize() {}
      void post_randomize() {}

      Constraint! q{} _esdl__lengthConstraint;
    };
  }

  ConstraintEngine getCstEngine();
  void pre_randomize();
  void post_randomize();
}

class Randomizable: RandomizableIntf
{
  mixin(_esdl__randomizable());
}

T _new(T, Args...) (Args args) {
  version(EMPLACE) {
    import std.stdio, std.conv, core.stdc.stdlib;
    size_t objSize = __traits(classInstanceSize, T);
    void* tmp = core.stdc.stdlib.malloc(objSize);
    if (!tmp) throw new Exception("Memory allocation failed");
    void[] mem = tmp[0..objSize];
    T obj = emplace!(T, Args)(mem, args);
  }
  else {
    T obj = new T(args);
  }
  return obj;
}

void _delete(T)(T obj) {
  clear(obj);
  core.stdc.stdlib.free(cast(void*)obj);
}

public void _esdl__initCstEngine(T) (T t) {
  t._esdl__cstEng = new ConstraintEngine(t._esdl__randSeed);
  with(t._esdl__cstEng) {
    _buddy = _new!Buddy(400, 400);
    _esdl__initCsts(t, t);
  }
}

// I is the index within the class
// CI is the cumulative index -- starts from the most derived class
// and increases as we move up in the class hierarchy
void _esdl__initCsts(size_t I=0, size_t CI=0, T, S)(T t, S s)
  if(is(T: RandomizableIntf) && is(T == class) &&
     is(S: RandomizableIntf) && is(S == class)) {
    static if (I < t.tupleof.length) {
      _esdl__initCst!(I, CI)(t, s);
      _esdl__initCsts!(I+1, CI+1) (t, s);
    }
    else static if(is(T B == super)
		   && is(B[0] : RandomizableIntf)
		   && is(B[0] == class)) {
	B[0] b = t;
	_esdl__initCsts!(0, CI) (b, s);
      }
  }

void _esdl__initCst(size_t I=0, size_t CI=0, T, S) (T t, S s) {
  import std.traits;
  import std.conv;
  import std.string;

  auto l = t.tupleof[I];
  alias typeof(l) L;
  enum string NAME = chompPrefix (t.tupleof[I].stringof, "t.");
  static if (is (L f == Constraint!C, immutable (char)[] C)) {
    l = new Constraint!(C, NAME, T, S)(t, s, t._esdl__cstEng, NAME,
				       cast(uint) t._esdl__cstEng.cstList.length);
    static if(NAME == "_esdl__lengthConstraint") {
      t._esdl__cstEng.arrayMaxLengthCst = l;
    }
    else {
      t._esdl__cstEng.cstList ~= l;
    }

  }
  else {
    synchronized (t) {
      // Do nothing
    }
  }
}

// I is the index within the class
// CI is the cumulative index -- starts from the most derived class
// and increases as we move up in the class hierarchy
void _esdl__initLengthCsts(size_t I=0, size_t CI=0, size_t RI=0, T)(T t, ref bdd solveBDD, CstStage stage)
  if(is(T: RandomizableIntf) && is(T == class)) {
    static if (I < t.tupleof.length) {
      if(findRandAttr!(I, t)) {
	_esdl__initLengthCst!(I, RI)(t, solveBDD, stage);
	_esdl__initLengthCsts!(I+1, CI+1, RI+1) (t, solveBDD, stage);
      }
      else {
	_esdl__initLengthCsts!(I+1, CI+1, RI) (t, solveBDD, stage);
      }
    }
    else static if(is(T B == super)
		   && is(B[0] : RandomizableIntf)
		   && is(B[0] == class)) {
	B[0] b = t;
	_esdl__initLengthCsts!(0, CI) (b, solveBDD, stage);
      }
  }

void _esdl__initLengthCst(size_t I=0, size_t RI=0, T) (T t, ref bdd solveBDD,
						       CstStage stage) {
  import std.traits;
  import std.conv;
  import std.string;

  auto l = t.tupleof[I];
  alias typeof(l) L;
  enum string NAME = chompPrefix (t.tupleof[I].stringof, "t.");
  static if(isDynamicArray!L) {
    enum RLENGTH = findRandArrayAttr!(I, t);
    auto cstVecPrim = t._cstRands[RI];
    if(cstVecPrim !is null && cstVecPrim.stage() == stage) {
      solveBDD &= cstVecPrim.getBDD(stage, solveBDD.root()).
	lte(_esdl__cstRand(RLENGTH, t).getBDD(stage, solveBDD.root()));
    }
  }
}

auto _esdl__namedApply(string VAR, alias F, size_t I=0, size_t CI=0, T)(T t)
if(is(T unused: RandomizableIntf) && is(T == class)) {
  static if (I < t.tupleof.length) {
    static if ("t."~_esdl__randVar!VAR.prefix == t.tupleof[I].stringof) {
      return F!(VAR, I, CI)(t);
    }
    else {
      return _esdl__namedApply!(VAR, F, I+1, CI+1) (t);
    }
  }
  else static if(is(T B == super)
		 && is(B[0] : RandomizableIntf)
		 && is(B[0] == class)) {
      B[0] b = t;
      return _esdl__namedApply!(VAR, F, 0, CI) (b);
    }
    else {
      static assert(false, "Can not map variable: " ~ VAR);
    }
 }

void _esdl__setRands(size_t I=0, size_t CI=0, size_t RI=0, T)
  (T t, CstVecPrim[] vecVals, ref RandGen rgen)
  if(is(T unused: RandomizableIntf) && is(T == class)) {
    import std.traits;
    static if (I < t.tupleof.length) {
      alias typeof(t.tupleof[I]) L;
      static if (isDynamicArray!L) {
	enum RLENGTH = findRandArrayAttr!(I, t);
	static if(RLENGTH != -1) { // is @rand
	  // make sure that there is only one dimension passed to @rand
	  static assert(findRandArrayAttr!(I, t, 1) == int.min);
	  // enum ATTRS = __traits(getAttributes, t.tupleof[I]);
	  // alias ATTRS[RLENGTH] ATTR;
	  auto vecVal = vecVals[RI];
	  if(vecVal is null) {
	    t.tupleof[I].length = rgen.gen(0, RLENGTH+1);
	  }
	  else {
	    t.tupleof[I].length = vecVal.value;
	  }
	  foreach(ref v; t.tupleof[I]) {
	    import std.range;
	    v = rgen.gen!(ElementType!L);
	  }
	  // t.tupleof[I] = rgen.gen!L;
	  // }
	  // else {
	  //   // t.tupleof[I] = cast(L) vecVal.value;
	  // }

	  _esdl__setRands!(I+1, CI+1, RI+1) (t, vecVals, rgen);
	}
	else {
	  _esdl__setRands!(I+1, CI+1, RI) (t, vecVals, rgen);
	}
      }
      else {
	static if(findRandElemAttr!(I, t) != -1) { // is @rand
	  static if(isStaticArray!L) {
	    foreach(ref v; t.tupleof[I]) {
	      import std.range;
	      v = rgen.gen!(ElementType!L);
	    }
	  }
	  else {
	    auto vecVal = vecVals[RI];
	    if(vecVal is null) {
	      t.tupleof[I] = rgen.gen!L;
	    }
	    else {
	      import esdl.data.bvec;
	      bvec!64 temp = vecVal.value;
	      t.tupleof[I] = cast(L) temp;
	    }
	  }
	  _esdl__setRands!(I+1, CI+1, RI+1) (t, vecVals, rgen);
	}
	else {
	  _esdl__setRands!(I+1, CI+1, RI) (t, vecVals, rgen);
	}
      }
    }
    else static if(is(T B == super)
		   && is(B[0] : RandomizableIntf)
		   && is(B[0] == class)) {
	B[0] b = t;
	_esdl__setRands!(0, CI, RI) (b, vecVals, rgen);
      }
  }

template findRandAttr(size_t I, alias t) {
  enum int randAttr =
    findRandElemAttrIndexed!(0, -1, __traits(getAttributes, t.tupleof[I]));
  enum int randsAttr =
    findRandArrayAttrIndexed!(0, -1, 0, __traits(getAttributes, t.tupleof[I]));
  enum bool findRandAttr = randAttr != -1 || randsAttr != -1;
}

template findRandElemAttr(size_t I, alias t) {
  enum int randAttr =
    findRandElemAttrIndexed!(0, -1, __traits(getAttributes, t.tupleof[I]));
  enum int randsAttr =
    findRandArrayAttrIndexed!(0, -1, 0, __traits(getAttributes, t.tupleof[I]));
  static assert(randsAttr == -1, "Illegal use of @rand!" ~ randsAttr.stringof);
  enum int findRandElemAttr = randAttr;
}

template findRandArrayAttr(size_t I, alias t, size_t R=0) {
  enum int randAttr =
    findRandElemAttrIndexed!(0, -1, __traits(getAttributes, t.tupleof[I]));
  enum int randsAttr =
    findRandArrayAttrIndexed!(0, -1, R, __traits(getAttributes, t.tupleof[I]));
  static assert(randAttr == -1,	"Illegal use of @rand");
  enum int findRandArrayAttr = randsAttr;
}

template findRandElemAttrIndexed(size_t C, int P, A...) {
  static if(A.length == 0) enum int findRandElemAttrIndexed = P;
  else static if(__traits(isSame, A[0], rand)) {
      static assert(P == -1, "@rand used twice in the same declaration");
      static if(A.length > 1)
	enum int findRandElemAttrIndexed = findRandElemAttrIndexed!(C+1, C, A[1..$]);
      else
	enum int findRandElemAttrIndexed = C;
    }
    else {
      enum int findRandElemAttrIndexed = findRandElemAttrIndexed!(C+1, P, A[1..$]);
    }
}

template findRandArrayAttrIndexed(size_t C, int P, size_t R, A...) {
  static if(A.length == 0) enum int findRandArrayAttrIndexed = P;
  else static if(is(A[0] unused: rand!M, M...)) {
      static assert(P == -1, "@rand used twice in the same declaration");
      static if(A.length > 1) {
	enum int findRandArrayAttrIndexed =
	  findRandArrayAttrIndexed!(C+1, C, R, A[1..$]);
      }
      else {
	static if(R < M.length && R >= 0) {
	  enum int findRandArrayAttrIndexed = M[R];
	}
	else {
	  enum int findRandArrayAttrIndexed = int.min;
	}
      }
    }
    else {
      enum int findRandArrayAttrIndexed =
	findRandArrayAttrIndexed!(C+1, P, R, A[1..$]);
    }
}

template isVarSigned(L) {
  import std.traits: isIntegral, isSigned;
  static if(isBitVector!L)
    enum bool isVarSigned = L.ISSIGNED;
  else static if(isIntegral!L)
	 enum bool isVarSigned = isSigned!L;
    else
      static assert(false, "isVarSigned: Can not determine sign of type " ~ typeid(L));
}

public bool randomize(T) (ref T t)
  if(is(T v: RandomizableIntf) &&
     is(T == class)) {
    import std.exception;
    import std.conv;

    if(t._cstRands.length is 0) {
      auto randCount = _esdl__countRands(t);
      t._cstRands.length = randCount;
    }

    // Call the pre_randomize hook
    t.pre_randomize();

    // Initialize the constraint database if not already done
    if (t._esdl__cstEng is null) {
      _esdl__initCstEngine(t);
    }

    auto values = t._cstRands;

    foreach(rnd; t._cstRands) {
      if(rnd !is null) {
	// stages would be assigned again from scratch
	rnd.stage = null;
	// FIXME -- Perhaps some other fields too need to be reinitialized
      }
    }

    t._esdl__cstEng.solve();

    values = t._cstRands;

    _esdl__setRands(t, values, t._esdl__cstEng._rgen);

    // Call the post_randomize hook
    t.post_randomize();
    return true;
  }




// All the operations that produce a BddVec
enum CstBinVecOp: byte
  {   AND,
      OR ,
      XOR,
      ADD,
      SUB,
      MUL,
      DIV,
      LSH,
      RSH,
      LOOPINDEX,
      BITINDEX,
      }

// All the operations that produce a Bdd
enum CstBinBddOp: byte
  {   LTH,
      LTE,
      GTH,
      GTE,
      EQU,
      NEQ,
      }

// proxy class for reading in the constraints lazily
// An abstract class that returns a vector on evaluation
abstract class CstVecExpr
{

  CstVecLoopVar[] _loopVars;

  public CstVecLoopVar[] loopVars() {
    return _loopVars;
  }

  CstVecRandArr[] _lengthVars;

  public CstVecRandArr[] lengthVars() {
    return _lengthVars;
  }

  // get all the primary bdd vectors that constitute a given bdd expression
  abstract public CstVecPrim[] getPrims();

  // get the list of stages this expression should be avaluated in
  abstract public CstStage[] getStages();

  abstract public BddVec getBDD(CstStage stage, Buddy buddy);

  abstract public long evaluate(CstStage stage);

  public CstVec2VecExpr opBinary(string op)(CstVecExpr other)
  {
    static if(op == "&") {
      return new CstVec2VecExpr(this, other, CstBinVecOp.AND);
    }
    static if(op == "|") {
      return new CstVec2VecExpr(this, other, CstBinVecOp.OR);
    }
    static if(op == "^") {
      return new CstVec2VecExpr(this, other, CstBinVecOp.XOR);
    }
    static if(op == "+") {
      return new CstVec2VecExpr(this, other, CstBinVecOp.ADD);
    }
    static if(op == "-") {
      return new CstVec2VecExpr(this, other, CstBinVecOp.SUB);
    }
    static if(op == "*") {
      return new CstVec2VecExpr(this, other, CstBinVecOp.MUL);
    }
    static if(op == "/") {
      return new CstVec2VecExpr(this, other, CstBinVecOp.DIV);
    }
    static if(op == "<<") {
      return new CstVec2VecExpr(this, other, CstBinVecOp.LSH);
    }
    static if(op == ">>") {
      return new CstVec2VecExpr(this, other, CstBinVecOp.RSH);
    }
  }

  public CstVec2VecExpr opIndex(CstVecExpr other)
  {
    assert(false, "Index operation defined only for Arrays");
  }

  public CstVecRand opIndex(size_t other)
  {
    assert(false, "Index operation defined only for Arrays");
  }

  public CstVec2BddExpr lth(CstVecExpr other) {
    return new CstVec2BddExpr(this, other, CstBinBddOp.LTH);
  }

  public CstVec2BddExpr lte(CstVecExpr other) {
    return new CstVec2BddExpr(this, other, CstBinBddOp.LTE);
  }

  public CstVec2BddExpr gth(CstVecExpr other) {
    return new CstVec2BddExpr(this, other, CstBinBddOp.GTH);
  }

  public CstVec2BddExpr gte(CstVecExpr other) {
    return new CstVec2BddExpr(this, other, CstBinBddOp.GTE);
  }

  public CstVec2BddExpr equ(CstVecExpr other) {
    return new CstVec2BddExpr(this, other, CstBinBddOp.EQU);
  }

  public CstVec2BddExpr neq(CstVecExpr other) {
    return new CstVec2BddExpr(this, other, CstBinBddOp.NEQ);
  }
}

class CstVecPrim: CstVecExpr
{
  abstract public bool isRand();
  abstract public long value();
  abstract public void value(long v);
  abstract public CstStage stage();
  abstract public void stage(CstStage s);
  abstract public uint domIndex();
  abstract public void domIndex(uint s);
  abstract public uint bitcount();
  abstract public bool signed();
  abstract public BddVec bddvec();
  abstract public void bddvec(BddVec b);
  abstract public string name();
}

// This class represents an unrolled Foreach loop at vec level
class CstVecLoopVar: CstVecPrim
{
  // _loopVar will point to the array this CstVecLoopVar is tied to
  CstVecPrim _loopVar;

  CstVecPrim loopVar() {
    return _loopVar;
  }

  override CstVecLoopVar[] loopVars() {
    return [this];
  }

  override CstVecRandArr[] lengthVars() {
    return [];
  }

  this(CstVecPrim loopVar) {
    _loopVar = loopVar;
  }

  bool isUnrollable(CstVecRand loopVar) {
    if(loopVar is _loopVar) {
      return true;
    }
    else {
      return false;
    }
  }

  bool isUnrollable(CstStage stage) {
    if(! _loopVar.isRand()) return true;
    if(_loopVar.stage.solved()) return true;
    else return false;
  }

  // get all the primary bdd vectors that constitute a given bdd expression
  override public CstVecPrim[] getPrims() {
    return _loopVar.getPrims();
  }

  // get the list of stages this expression should be avaluated in
  override public CstStage[] getStages() {
    return _loopVar.getStages();
  }

  override public BddVec getBDD(CstStage stage, Buddy buddy) {
    assert(false, "Can not getBDD for a Loop Variable without unrolling");
  }

  override public long evaluate(CstStage stage) {
    assert(false, "Can not evaluate for a Loop Variable without unrolling");
  }

  override public bool isRand() {
    return loopVar.isRand();
  }
  override public long value() {
    return loopVar.value();
  }
  override public void value(long v) {
    loopVar.value(v);
  }
  override public CstStage stage() {
    return loopVar.stage();
  }
  override public void stage(CstStage s) {
    loopVar.stage(s);
  }
  override public uint domIndex() {
    return loopVar.domIndex;
  }
  override public void domIndex(uint s) {
    loopVar.domIndex(s);
  }
  override public uint bitcount() {
    return loopVar.bitcount();
  }
  override public bool signed() {
    return loopVar.signed();
  }
  override public BddVec bddvec() {
    return loopVar.bddvec();
  }
  override public void bddvec(BddVec b) {
    loopVar.bddvec(b);
  }
  override public string name() {
    return loopVar.name();
  }
}

class CstVecRandArr: CstVecRand
{
  // Base class object shall be used for constraining the length part
  // of the array.

  // Also has an array of CstVecRand to map all the elements of the
  // array
  CstVecRand[] _elems;
  bool _elemSigned;
  uint _elemBitcount;
  bool _elemIsRand;

  size_t _maxValue = 0;

  size_t maxValue() {
    return _maxValue;
  }

  public CstVecPrim[] getArrPrims() {
    CstVecPrim[] elems;
    foreach (elem; _elems) {
      elems ~= elem;
    }
    return elems;
  }
  
  override public CstVecRandArr[] lengthVars() {
    if(isRand()) return [this];
    else return [];
  }

  bool isUnrollable(CstStage stage) {
    if(! isRand) return true;
    if(this.stage.solved()) return true;
    else return false;
  }

  override public CstVec2VecExpr opIndex(CstVecExpr idx) {
    return new CstVec2VecExpr(this, idx, CstBinVecOp.LOOPINDEX);
  }

  override public CstVecRand opIndex(size_t idx) {
    return _elems[idx];
  }

  void opIndexAssign(CstVecRand c, size_t idx) {
    _elems[idx] = c;
  }

  public this(string name, long value,
	      bool signed, uint bitcount, bool isRand,
	      bool elemSigned, uint elemBitcount, bool elemIsRand) {
    super(name, value, signed, bitcount, isRand);
    static uint id;
    _name = name;
    _value = value;
    _maxValue = value;
    _signed = signed;
    _bitcount = bitcount;
    _isRand = isRand;
    _elemSigned = elemSigned;
    _elemBitcount = elemBitcount;
    _elemIsRand = elemIsRand;
    _elems.length = value;
  }
}

class CstVecRand: CstVecPrim
{
  BddVec _bddvec;
  uint _domIndex = uint.max;
  long _value;
  uint _bitcount;
  CstStage _stage = null;
  bool _signed;
  bool _isRand;
  string _name;

  override string name() {
    return _name;
  }

  public this(string name, long value, bool signed,
	      uint bitcount, bool isRand) {
    static uint id;
    _name = name;
    _value = value;
    _signed = signed;
    _bitcount = bitcount;
    _isRand = isRand;
  }

  override public CstVecPrim[] getPrims() {
    CstVecPrim[] _prims;
    if(isRand) _prims = [this];
    return _prims;
  }

  override public CstStage[] getStages() {
    CstStage[] stages;
    if(isRand) stages = [this.stage()];
    return stages;
  }

  override public BddVec getBDD(CstStage stage, Buddy buddy) {
    if(this.isRand && stage is _stage) {
      return _bddvec;
    }
    else if((! this.isRand) ||
	    this.isRand && _stage.solved()) { // work with the value
      return buddy.buildVec(_value);
    }
    else {
      assert(false, "Constraint evaluation in wrong stage");
    }
  }

  override public long evaluate(CstStage stage) {
    if(! this.isRand || _stage.solved()) {
      return _value;
    }
    else {
      assert(false, "Constraint evaluation in wrong stage");
    }
  }

  override public bool isRand() {
    return _isRand;
  }

  override public long value() {
    return _value;
  }

  override public void value(long v) {
    _value = v;
  }

  override public CstStage stage() {
    return _stage;
  }

  override public void stage(CstStage s) {
    _stage = s;
  }

  override public uint domIndex() {
    return _domIndex;
  }

  override public void domIndex(uint s) {
    _domIndex = s;
  }

  override public uint bitcount() {
    return _bitcount;
  }

  override public bool signed() {
    return _signed;
  }

  override public BddVec bddvec() {
    return _bddvec;
  }

  override public void bddvec(BddVec b) {
    _bddvec = b;
  }

  public T to(T)()
    if(is(T == string)) {
      import std.conv;
      if(isRand) {
	return "RAND-" ~ "#" ~ _name ~ "-" ~ _value.to!string();
      }
      else {
	return "VAL#" ~ _name ~ "-" ~ _value.to!string();
      }
    }

  override public string toString() {
    return this.to!string();
  }

}

class CstVecConst: CstVecPrim
{
  long _value;			// the value of the constant
  bool _signed;

  public this(long value, bool signed) {
    _value = value;
    _signed = signed;
  }

  override public CstVecPrim[] getPrims() {
    return [];
  }

  override public CstStage[] getStages() {
    return [];
  }

  override public BddVec getBDD(CstStage stage, Buddy buddy) {
    return buddy.buildVec(_value);
  }

  override public long evaluate(CstStage stage) {
    return _value;
  }

  override public bool isRand() {
    return false;
  }

  override public long value() {
    return _value;
  }

  override public void value(long v) {
    _value = value;
  }

  override public CstStage stage() {
    assert(false, "no stage for CstVecConst");
  }

  override public void stage(CstStage s) {
    assert(false, "no stage for CstVecConst");
  }

  override public uint domIndex() {
    assert(false, "no domIndex for CstVecConst");
  }

  override public void domIndex(uint s) {
    assert(false, "no domIndex for CstVecConst");
  }

  override public uint bitcount() {
    assert(false, "no bitcount for CstVecConst");
  }

  override public bool signed() {
    return _signed;
  }

  override public BddVec bddvec() {
    assert(false, "no bddvec for CstVecConst");
  }

  override public void bddvec(BddVec b) {
    assert(false, "no bddvec for CstVecConst");
  }

  override public string name() {
    return "CstVecConst";
  }
}

// This class would hold two(bin) vector nodes and produces a vector
// only after processing those two nodes
class CstVec2VecExpr: CstVecExpr
{
  CstVecExpr _lhs;
  CstVecExpr _rhs;
  CstBinVecOp _op;

  override public CstVecPrim[] getPrims() {
    if(_op !is CstBinVecOp.LOOPINDEX || _rhs.loopVars.length is 0) {
      return _lhs.getPrims() ~ _rhs.getPrims();
    }
    else {
      // LOOP
      // first make sure that the _lhs is an array
      auto lhs = cast(CstVecRandArr) _lhs;
      // FIXME -- what if the LOOPINDEX is use with non-rand array?
      assert(lhs !is null, "LOOPINDEX can not work with non-arrays");
      return lhs.getArrPrims();
    }
  }

  override public CstStage[] getStages() {
    import std.exception;
    import std.algorithm: max;

    enforce(_lhs.getStages.length <= 1 &&
	    _rhs.getStages.length <= 1);

    if(_lhs.getStages.length is 0) return _rhs.getStages;
    else if(_rhs.getStages.length is 0) return _lhs.getStages;
    else {
      // Stages need to be merged
      // uint stage = max(_lhs.getStages[0], _rhs.getStages[0]);
      // return [stage];
      return _lhs.getStages;
    }
  }

  override public BddVec getBDD(CstStage stage, Buddy buddy) {
    if(this.loopVars.length !is 0) {
      assert(false,
	     "CstVec2VecExpr: Need to unroll the loopVars"
	     " before attempting to solve BDD");
    }
    BddVec vec;

    auto lvec = _lhs.getBDD(stage, buddy);
    auto rvec = _rhs.getBDD(stage, buddy);

    final switch(_op) {
    case CstBinVecOp.AND: return lvec &  rvec;
    case CstBinVecOp.OR:  return lvec |  rvec;
    case CstBinVecOp.XOR: return lvec ^  rvec;
    case CstBinVecOp.ADD: return lvec +  rvec;
    case CstBinVecOp.SUB: return lvec -  rvec;
    case CstBinVecOp.MUL: return lvec *  rvec;
    case CstBinVecOp.DIV: return lvec /  rvec;
    case CstBinVecOp.LSH: return lvec << rvec;
    case CstBinVecOp.RSH: return lvec >> rvec;
    case CstBinVecOp.LOOPINDEX: return _lhs[_rhs.evaluate(stage)].getBDD(stage, buddy);
    case CstBinVecOp.BITINDEX: {
      assert(false, "BITINDEX is not implemented yet!");
    }
    }
  }

  override public long evaluate(CstStage stage) {
    auto lvec = _lhs.evaluate(stage);
    auto rvec = _rhs.evaluate(stage);

    final switch(_op) {
    case CstBinVecOp.AND: return lvec &  rvec;
    case CstBinVecOp.OR:  return lvec |  rvec;
    case CstBinVecOp.XOR: return lvec ^  rvec;
    case CstBinVecOp.ADD: return lvec +  rvec;
    case CstBinVecOp.SUB: return lvec -  rvec;
    case CstBinVecOp.MUL: return lvec *  rvec;
    case CstBinVecOp.DIV: return lvec /  rvec;
    case CstBinVecOp.LSH: return lvec << rvec;
    case CstBinVecOp.RSH: return lvec >> rvec;
    case CstBinVecOp.LOOPINDEX: return _lhs[rvec].evaluate(stage);
    case CstBinVecOp.BITINDEX: {
      assert(false, "BITINDEX is not implemented yet!");
    }
    }
  }

  public this(CstVecExpr lhs, CstVecExpr rhs, CstBinVecOp op) {
    _lhs = lhs;
    _rhs = rhs;
    _op = op;
    foreach(loopVar; lhs.loopVars ~ rhs.loopVars) {
      bool add = true;
      foreach(l; _loopVars) {
	if(l is loopVar) add = false;
	break;
      }
      if(add) _loopVars ~= loopVar;
    }
    foreach(lengthVar; lhs.lengthVars ~ rhs.lengthVars) {
      if(op !is CstBinVecOp.LOOPINDEX) {
	bool add = true;
	foreach(l; _lengthVars) {
	  if(l is lengthVar) add = false;
	  break;
	}
	if(add) _lengthVars ~= lengthVar;
      }
    }
  }

}

class CstNotVecExpr: CstVecExpr
{
}

enum CstBddOp: byte
  {   AND,
      OR ,
      IMP,
      }

abstract class CstBddExpr
{

  // In case this expr is unRolled, the _loopVars here would be empty
  CstVecLoopVar[] _loopVars;

  public CstVecLoopVar[] loopVars() {
    return _loopVars;
  }

  CstVecRandArr[] _lengthVars;

  public CstVecRandArr[] lengthVars() {
    return _lengthVars;
  }

  abstract public CstVecPrim[] getPrims();

  abstract public CstStage[] getStages();

  abstract public bdd getBDD(CstStage stage, Buddy buddy);

  public CstBdd2BddExpr opBinary(string op)(CstBddExpr other)
  {
    static if(op == "&") {
      return new CstBdd2BddExpr(this, other, CstBddOp.AND);
    }
    static if(op == "|") {
      return new CstBdd2BddExpr(this, other, CstBddOp.OR);
    }
  }

  public CstBdd2BddExpr imp(CstBddExpr other)
  {
    return new CstBdd2BddExpr(this, other, CstBddOp.IMP);
  }

}

class CstBdd2BddExpr: CstBddExpr
{
  CstBddExpr _lhs;
  CstBddExpr _rhs;
  CstBddOp _op;

  override public CstVecPrim[] getPrims() {
    return _lhs.getPrims() ~ _rhs.getPrims();
  }

  override public CstStage[] getStages() {
    CstStage[] stages;

    foreach(lstage; _lhs.getStages) {
      bool already = false;
      foreach(stage; stages) {
	if(stage is lstage) {
	  already = true;
	}
      }
      if(! already) stages ~= lstage;
    }
    foreach(rstage; _rhs.getStages) {
      bool already = false;
      foreach(stage; stages) {
	if(stage is rstage) {
	  already = true;
	}
      }
      if(! already) stages ~= rstage;
    }

    return stages;
  }

  override public bdd getBDD(CstStage stage, Buddy buddy) {
    if(this.loopVars.length !is 0) {
      assert(false,
	     "CstBdd2BddExpr: Need to unroll the loopVars"
	     " before attempting to solve BDD");
    }
    auto lvec = _lhs.getBDD(stage, buddy);
    auto rvec = _rhs.getBDD(stage, buddy);

    final switch(_op) {
    case CstBddOp.AND: return lvec &  rvec;
    case CstBddOp.OR:  return lvec |  rvec;
    case CstBddOp.IMP: return lvec.imp(rvec);
    }
  }

  public this(CstBddExpr lhs, CstBddExpr rhs, CstBddOp op) {
    _lhs = lhs;
    _rhs = rhs;
    _op = op;
    foreach(loopVar; lhs.loopVars ~ rhs.loopVars) {
      bool add = true;
      foreach(l; _loopVars) {
	if(l is loopVar) add = false;
	break;
      }
      if(add) _loopVars ~= loopVar;
    }
    foreach(lengthVar; lhs.lengthVars ~ rhs.lengthVars) {
      bool add = true;
      foreach(l; _lengthVars) {
	if(l is lengthVar) add = false;
	break;
      }
      if(add) _lengthVars ~= lengthVar;
    }
  }
}


class CstIteBddExpr: CstBddExpr
{
}

class CstVec2BddExpr: CstBddExpr
{
  CstVecExpr _lhs;
  CstVecExpr _rhs;
  CstBinBddOp _op;

  override public CstStage[] getStages() {
    import std.exception;
    import std.algorithm: max;
    enforce(_lhs.getStages.length <= 1 &&
	    _rhs.getStages.length <= 1);

    if(_lhs.getStages.length is 0) return _rhs.getStages;
    else if(_rhs.getStages.length is 0) return _lhs.getStages;
    else {
      // uint stage = max(_lhs.getStages[0], _rhs.getStages[0]);
      // return [stage];
      return _lhs.getStages;
    }
  }

  override public CstVecPrim[] getPrims() {
    return _lhs.getPrims() ~ _rhs.getPrims();
  }

  override public bdd getBDD(CstStage stage, Buddy buddy) {
    if(this.loopVars.length !is 0) {
      assert(false,
	     "CstVec2BddExpr: Need to unroll the loopVars"
	     " before attempting to solve BDD");
    }
    auto lvec = _lhs.getBDD(stage, buddy);
    auto rvec = _rhs.getBDD(stage, buddy);

    final switch(_op) {
    case CstBinBddOp.LTH: return lvec.lth(rvec);
    case CstBinBddOp.LTE: return lvec.lte(rvec);
    case CstBinBddOp.GTH: return lvec.gth(rvec);
    case CstBinBddOp.GTE: return lvec.gte(rvec);
    case CstBinBddOp.EQU: return lvec.equ(rvec);
    case CstBinBddOp.NEQ: return lvec.neq(rvec);
    }
  }

  public this(CstVecExpr lhs, CstVecExpr rhs, CstBinBddOp op) {
    _lhs = lhs;
    _rhs = rhs;
    _op = op;
    foreach(loopVar; lhs.loopVars ~ rhs.loopVars) {
      bool add = true;
      foreach(l; _loopVars) {
	if(l is loopVar) add = false;
	break;
      }
      if(add) _loopVars ~= loopVar;
    }
    foreach(lengthVar; lhs.lengthVars ~ rhs.lengthVars) {
      bool add = true;
      foreach(l; _lengthVars) {
	if(l is lengthVar) add = false;
	break;
      }
      if(add) _lengthVars ~= lengthVar;
    }
  }
}

class CstNotBddExpr: CstBddExpr
{
}

class CstBlock: CstBddExpr
{
  CstBddExpr _exprs[];

  override public CstVecPrim[] getPrims() {
    CstVecPrim[] prims;

    foreach(expr; _exprs) {
      prims ~= expr.getPrims();
    }

    return prims;
  }

  override public CstStage[] getStages() {
    CstStage[] stages;

    foreach(expr; _exprs) {
      foreach(lstage; expr.getStages) {
	bool already = false;
	foreach(stage; stages) {
	  if(stage is lstage) {
	    already = true;
	  }
	}
	if(! already) stages ~= lstage;
      }
    }

    return stages;
  }

  override public bdd getBDD(CstStage stage, Buddy buddy) {
    assert(false, "getBDD not implemented for CstBlock");
  }

  public void opOpAssign(string op)(CstBddExpr other)
    if(op == "~") {
      _exprs ~= other;
    }

  public void opOpAssign(string op)(CstBlock other)
    if(op == "~") {
      foreach(expr; other._exprs) {
      _exprs ~= expr;
      }
    }
}

auto _esdl__randNamedApply(string VAR, alias F, size_t I=0,
			   size_t CI=0, size_t RI=0, T)(T t)
if(is(T unused: RandomizableIntf) && is(T == class)) {
  static if (I < t.tupleof.length) {
    static if ("t."~_esdl__randVar!VAR.prefix == t.tupleof[I].stringof) {
      return F!(VAR, I, CI, RI)(t);
    }
    else {
      static if(findRandAttr!(I, t) != -1) {
	return _esdl__randNamedApply!(VAR, F, I+1, CI+1, RI+1) (t);
      }
      else {
	return _esdl__randNamedApply!(VAR, F, I+1, CI+1, RI) (t);
      }
    }
  }
  else static if(is(T B == super)
		 && is(B[0] : RandomizableIntf)
		 && is(B[0] == class)) {
      B[0] b = t;
      return _esdl__randNamedApply!(VAR, F, 0, CI, RI) (b);
    }
    else {
      static assert(false, "Can not map variable: " ~ VAR);
    }
 }

private size_t _esdl__cstDelimiter(string name) {
  foreach(i, c; name) {
    if(c is '.' || c is '[') {
      return i;
    }
  }
  return name.length;
}

public CstVecConst _esdl__cstRand(INT, T)(INT var, ref T t)
  if(isIntegral!INT && is(T f: RandomizableIntf) && is(T == class)) {
    return new CstVecConst(var, isVarSigned!INT);
  }

public CstVecPrim _esdl__cstRand(string VAR, T)(ref T t)
  if(is(T f: RandomizableIntf) && is(T == class)) {
    enum IDX = _esdl__cstDelimiter(VAR);
    enum LOOKUP = VAR[0..IDX];
    static if(IDX == VAR.length) {
      return _esdl__randNamedApply!(LOOKUP, _esdl__cstRand)(t);
    }
    else static if(VAR[IDX..$] == ".length") {
	return _esdl__randNamedApply!(LOOKUP, _esdl__cstRandArrLength)(t);
    }
    else static if(VAR[IDX] == '.') {
      // hierarchical constraints -- not implemented yet
    }
    else static if(VAR[IDX] == '[') {
	// hmmmm
      }
}

public CstVecPrim _esdl__cstRand(string VAR, size_t I,
				size_t CI, size_t RI, T)(ref T t) {
  import std.traits: isIntegral;

  // need to know the size and sign for creating a bddvec
  alias typeof(t.tupleof[I]) L;
  static assert(isIntegral!L || isBitVector!L);

  static if(isVarSigned!L) bool signed = true;
  else                     bool signed = false;

  static if(isIntegral!L)       uint bitcount = L.sizeof * 8;
  else static if(isBitVector!L) uint bitcount = L.SIZE;
    else static assert(false, "Only numeric or bitvector expression"
		       "are allowed in constraint expressions");

  static if(findRandElemAttr!(I, t) == -1) {
    return _esdl__cstRand(t.tupleof[I], t);
  }
  else {
    auto cstVecPrim = t._cstRands[RI];
    if(cstVecPrim is null) {
      cstVecPrim = new CstVecRand(t.tupleof[I].stringof, t.tupleof[I],
				  signed, bitcount, true);
      t._cstRands[RI] = cstVecPrim;
    }
    return cstVecPrim;
  }
}

public CstVecPrim _esdl__cstRandElem(string VAR, T)(ref T t)
  if(is(T f: RandomizableIntf) && is(T == class)) {
    return _esdl__randNamedApply!(VAR, _esdl__cstRandElem)(t);
  }

public CstVecPrim _esdl__cstRandElem(string VAR, size_t I,
				     size_t CI, size_t RI, T)(ref T t) {
  import std.traits: isIntegral;
  import std.range: ElementType;

  static assert(isArray!L);
  // need to know the size and sign for creating a bddvec
  alias typeof(t.tupleof[I]) L;
  alias ElementType!L E;

  static assert(isIntegral!E || isBitVector!E);

  static if(isVarSigned!E) bool signed = true;
  else                     bool signed = false;

  static if(isIntegral!L)       uint bitcount = L.sizeof * 8;
  else static if(isBitVector!L) uint bitcount = L.SIZE;
    else static assert(false, "Only numeric or bitvector expression"
		       "are allowed in constraint expressions");

  static if(findRandElemAttr!(I, t) == -1) {
    auto cstVecPrim = new CstVecRand(t.tupleof[I].stringof, t.tupleof[I],
				     signed, bitcount, false);
  }
  else {
    auto cstVecPrim = t._cstRands[RI];
    if(cstVecPrim is null) {
      cstVecPrim = new CstVecRand(t.tupleof[I].stringof, t.tupleof[I],
				  signed, bitcount, true);
      t._cstRands[RI] = cstVecPrim;
    }
  }
  return cstVecPrim;
}

public CstVecPrim _esdl__cstRandArrLength(string VAR, size_t I,
				    size_t CI, size_t RI, T)(ref T t) {
  import std.traits;
  import std.range;

  // need to know the size and sign for creating a bddvec
  alias typeof(t.tupleof[I]) L;
  static assert(isArray!L);
  alias ElementType!L E;
  static assert(isIntegral!E || isBitVector!E);

  bool signed = isVarSigned!E;
  static if(isIntegral!E)        uint bitcount = E.sizeof * 8;
  else static if(isBitVector!E)  uint bitcount = E.SIZE;


  if(findRandAttr!(I, t) == -1) { // no @rand attr
    return _esdl__cstRand(t.tupleof[I].length, t);
  }
  else static if(isDynamicArray!L) { // @rand!N form
      enum RLENGTH = findRandArrayAttr!(I, t);
      static assert(RLENGTH != -1);
      auto cstVecPrim = t._cstRands[RI];
      if(cstVecPrim is null) {
	cstVecPrim = new CstVecRandArr(t.tupleof[I].stringof, RLENGTH,
				       false, 32, true, signed, bitcount, true);
	t._cstRands[RI] = cstVecPrim;
      }
      return cstVecPrim;
    }
  else static if(isStaticArray!L) { // @rand with static array
      enum ISRAND = findRandElemAttr!(I, t);
      static assert(ISRAND !is -1);
      auto cstVecPrim = t._cstRands[RI];
      if(cstVecPrim is null) {
	cstVecPrim = new CstVecRandArr(t.tupleof[I].stringof, t.tupleof[I].length,
				       false, 32, false, signed, bitcount, true);
	t._cstRands[RI] = cstVecPrim;
      }
      return cstVecPrim;
    }
    else static assert("Can not use .length with non-arrays");
}

public CstVecPrim _esdl__cstRandArrElem(string VAR, size_t I,
					size_t CI, size_t RI, T)(ref T t) {
  import std.traits;
  import std.range;

  // need to know the size and sign for creating a bddvec
  alias typeof(t.tupleof[I]) L;
  static assert(isArray!L);
  alias ElementType!L E;
  static assert(isIntegral!E || isBitVector!E);

  bool signed = isVarSigned!E;
  static if(isIntegral!E)        uint bitcount = E.sizeof * 8;
  else static if(isBitVector!E)  uint bitcount = E.SIZE;


  if(findRandAttr!(I, t) == -1) { // no @rand attr
    return _esdl__cstRand(t.tupleof[I].length, t);
  }
  else {
    auto cstVecPrim = t._cstRands[RI];
    auto cstVecRandArr = cast(CstVecRandArr) cstVecPrim;
    if(cstVecRandArr is null && cstVecPrim !is null) {
      assert(false, "Non-array CstVecPrim for an Array");
    }
    static if(isDynamicArray!L) { // @rand!N form
      enum size_t RLENGTH = findRandArrayAttr!(I, t);
      static assert(RLENGTH != -1);
      if(cstVecRandArr is null) {
	cstVecRandArr = new CstVecRandArr(t.tupleof[I].stringof, RLENGTH,
				       false, 32, true, signed, bitcount, true);
	t._cstRands[RI] = cstVecRandArr;
      }
    }
    else static if(isStaticArray!L) { // @rand with static array
	enum ISRAND = findRandElemAttr!(I, t);
	static assert(ISRAND !is -1);
	size_t RLENGTH = t.tupleof[I].length;
	if(cstVecRandArr is null) {
	  cstVecRandArr = new CstVecRandArr(t.tupleof[I].stringof, RLENGTH,
					 false, 32, false, signed, bitcount, true);
	  t._cstRands[RI] = cstVecRandArr;
	}
      }
      else static assert("Can not use .length with non-arrays");
    for (size_t i=0; i!=RLENGTH; ++i) {
      if(cstVecRandArr[i] is null) {
	import std.conv: to;
	auto init = (ElementType!(typeof(t.tupleof[I]))).init;
	if(i < t.tupleof[I].length) {
	  cstVecRandArr[i] = new CstVecRand(t.tupleof[I].stringof ~ "[" ~ i.to!string() ~ "]",
					    t.tupleof[I][i], signed, bitcount, true);
	}
	else {
	  cstVecRandArr[i] = new CstVecRand(t.tupleof[I].stringof ~ "[" ~ i.to!string() ~ "]",
					    init, signed, bitcount, true);
	}
      }
    }
    return cstVecRandArr;
  }
}

public CstVecLoopVar _esdl__cstRandArrIndex(string VAR, T)(ref T t)
  if(is(T f: RandomizableIntf) && is(T == class)) {
    return _esdl__randNamedApply!(VAR, _esdl__cstRandArrIndex)(t);
  }

public CstVecLoopVar _esdl__cstRandArrIndex(string VAR, size_t I,
					 size_t CI, size_t RI, T)(ref T t) {
  return new CstVecLoopVar(_esdl__cstRandArrLength!(VAR, I, CI, RI, T)(t));
}

public CstVecExpr _esdl__cstRandArrElem(string VAR, T)(ref T t)
  if(is(T f: RandomizableIntf) && is(T == class)) {
    auto arr = _esdl__randNamedApply!(VAR, _esdl__cstRandArrElem)(t);
    auto idx = new CstVecLoopVar(arr);
    return arr[idx];
  }
