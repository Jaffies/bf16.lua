---BF16.lua (by @jaffies)
---Usage:
---```bash
---cat input.b | luajit main.lua | luajit
---```
---Or (with input)
---```bash
---cat input.b | luajit main.lua > output.lua
---cat input.txt | luajit output.lua > output.txt
---```

local DEV = false
local SHOW_STATS = false
local SHOW_CODE = true

local BUFFER_SIZE = 30000 -- 30000 size is original brainfuck size
local BUFFER_PADDING = 1000 -- Padding to our buffer (so we wont error on MultXY if OOB)
local SAFE_MODE = false -- Forces stuff such as MultXY/MultXYZ to be memory safe, but loses performance (Wont cause segmentation fault in FFI mode).
local USE_UNSTABLE = false -- Allows to use unstable (5th pass) passes

local FFI = false -- Uses FFI mode (Very fast, but can cause bugs and works only in luajit)
local FFI_USE_RAYLIB = false -- Uses raylib to visualize first 256 memory cells (BF16-greyscale mode)
local FFI_SAFE_MODE = false -- Will force ffi to not cause segmentation fault, but will throw error instead! SLOWS PERFORMANCE BY A LOT
---@type 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7
local O = 7 -- Optimization level

---Internal
local SCAN_MAX_LENGTH = 30000 -- Max scan range
local MIN_COUNT_TO_SHRINK = 12 --Only 10 repeated asts will be shrinked as cycle, since otherwise it will be a perf. loss (and we do hotloops at 10), so yeah
local MIN_COUNT_TO_MEMSET = FFI and not FFI_SAFE_MODE and 4 or MIN_COUNT_TO_SHRINK -- For Free|FreeX operation its different because when we use FFI,

---@return string
local function readIO()
	return io.read("*a"):gsub("[^%+%-%>%<%.%,%/%`%[%]]", "")
end

---Default

---@alias Right 0 -- Pointer to right by 1
---@alias Left 1 -- Pointer to left by 1
---@alias Add 2 -- Add to cell by 1
---@alias Sub 3 -- Subb from cell by 1
---@alias Start 4 -- Start loop
---@alias End 5 -- End loop (not used internally though, only in compilation)
---@alias Read 6 -- Read cell
---@alias Write 7 --Write cell to IO (in ascii)
---@alias EntryPoint 8 -- EntryPoint (internally)

---Pass 1 (Folding linear instructions)

---@alias RightX 9 -- Pointer to right by X
---@alias LeftX 10 -- Pointer to left by X
---@alias AddX 11 -- Add to cell by X
---@alias SubX 12 -- Sub from cell by X

---Pass2 (Cycles -> Linear instructions)

---@alias MultXY 13 -- Mult cell (offseted by Y) by X from current block (cell[current + y] = cell[current + y] + cell[current] * x)
---@alias Free 14 -- Free currentcell
---@alias ScanRightX 15 -- Scans for any non 0 byte in right (in X steps)
---@alias ScanLeftX 16 -- Scans for any non 0 byte in left (in X steps)

---Pass3 (Cycles -> For/If constructions)
---@alias ForX 30 -- for _ = 1, buffer[index], X do ... end
---@alias If 31 -- if buffer[index] then ... e

---Pass4 doesnt have any new Ops
---Since all it does is shrinking

---Pass5 (Offsetting, previously was pass3)

---@alias AddXY 17 -- Adds cell by X by Y offset
---@alias SubXY 18 -- Subs cell by X by Y offset
---@alias MultXYZ 19 -- Same mult by with 2nd offset (to not update pointer)
---@alias FreeX 20 -- Frees cell with offset
---@alias ScanRightXY 21 -- Scans to right by offset Y (in X steps)
---@alias ScanLeftXY 22 -- Scans to left by offset Y (in X steps)
---@alias ReadX 23 -- Reads by offset X
---@alias WriteX 24 -- Writes by offset X
---@alias AddY 25 -- Adds cell by 1 by Y offset
---@alias SubY 26 -- Subs cell by 1 by Y offset

---Pass6
---@alias RepeatedFreeXY 32 -- for i = 0, Y - 1, Z do buffer[index+X+i] = 0 end
---@alias RepeatedAddXYZW 33 -- for i = 0, Z - 1, W do buffer[index+Y+i] = buffer[index+Y+i] + X end
---@alias RepeatedSubXYZW 33 -- for i = 0, Z - 1, W do buffer[index+Y+i] = buffer[index+Y+i] - X end
---@alias RepeatedMultXYZW 35 -- for i = 0, Y - 1 do Mult(X)(Y+i)(Z) end # THE ONLY THING WITHOUT STEPS, STEPS IS ALWAYS 1

---Pass7 (Previously was pass4, pattern matching)
---REMOVED, NOT USED
---TODO: Remake this shit from scratch (or remove it)
---@alias AssignXY 27 -- buffer[index+Y] = buffer[index+X+Y] (After than instruction there should be FreeX cuz of temp cell)
---@alias PlusXY 28 -- buffer[index+Y] = buffer[index+X+Y]+buffer[index+Y]
---@alias MultiplyXY 29 -- buffer[index+Y] = buffer[index+Y] * buffer[index+X+Y] DO NOT CONFUSE WITH MULT

---@alias Operation Right | Left | Add | Sub | Start | End | Read | Write | EntryPoint | RightX | LeftX | AddX | SubX | MultXY | Free | ScanLeftX | ScanRightX | AddXY | SubXY | MultXYZ | FreeX | ScanLeftXY | ScanRightXY | ReadX | WriteX | AddY | SubY | AssignXY | PlusXY | MultiplyXY | ForX | If

---@type Operation[]
local commands = {}
local commandsLength = 0

---Just simple parsing to command buffer
do
	local operators = {
		[">"] = 0 --[[@as Right]],
		["<"] = 1 --[[@as Left]],
		["+"] = 2 --[[@as Add]],
		["-"] = 3 --[[@as Sub]],
		["["] = 4 --[[@as Start]],
		["]"] = 5 --[[@as End]],
		[","] = 6 --[[@as Read]],
		["."] = 7 --[[@as Write]],
	}

	local stdin = readIO()

	for i = 1, #stdin do
		if operators[string.sub(stdin, i, i)] then
			commands[#commands + 1] = operators[string.sub(stdin, i, i)]
		end
	end

	commandsLength = #commands
	if DEV or SHOW_STATS then
		print("Made commands buffer, its length is", commandsLength)
	end
end

---@class AstOperation
---@field id Operation
---@field children AstOperation[]|nil
---@field x integer?
---@field y integer?
---@field z integer?
---@field w integer?

---@type AstOperation
local ast = {
	id = 8, -- Internal
	children = {},
}

---@param to AstOperation
---@param toAdd AstOperation
local function addToAst(to, toAdd)
	if to.children then
		to.children[#to.children + 1] = toAdd
	end
end

local function dump(o)
	if type(o) == "table" then
		local s = "{ "
		for k, v in pairs(o) do
			if type(k) ~= "number" then
				k = '"' .. k .. '"'
			end
			s = s .. "[" .. k .. "] = " .. dump(v) .. ","
		end
		return s .. "} "
	else
		return tostring(o)
	end
end

local function renderAst()
	print(dump(ast.children))
end

---Parsing command buffer to AST
do
	---@param startRange integer
	---@param currentAst AstOperation
	---@return integer
	local function parseOperator(startRange, currentAst)
		local i = startRange

		while i <= commandsLength do
			local operator = commands[i]

			if operator == 0 or operator == 1 or operator == 2 or operator == 3 or operator == 6 or operator == 7 then
				local toAdd = {
					id = operator,
				}

				addToAst(currentAst, toAdd)
				i = i + 1
			elseif operator == 4 then
				local toAdd = {
					id = 4,
					children = {},
				}

				local length = parseOperator(i + 1, toAdd) + 2

				i = i + length
				addToAst(currentAst, toAdd)
			elseif operator == 5 then
				if currentAst.id == 8 then
					error("AST error: found ] where no any cycle has begun")
				end

				return i - startRange
			end
		end

		if currentAst.id ~= 8 then
			error("AST error: found <eof> where we have active cycle!\nConsider adding ]")
		end

		return commandsLength - startRange
	end

	parseOperator(1, ast)

	if DEV or SHOW_STATS then
		print("Created AST tree, its length (on first level) is", #ast.children)
		if DEV then
			renderAst()
		end
	end
end

---First optimization pass

do
	local pass1LookupId = {
		[0 --[[@as Right]]] = 9 --[[@as RightX]],
		[1 --[[@as Left]]] = 10 --[[@as LeftX]],
		[2 --[[@as Add]]] = 11 --[[@as AddX]],
		[3 --[[@as Sub]]] = 12 --[[@as SubX]],
	}

	local timesFolded = 0

	---@param currentAst AstOperation
	---@return AstOperation -- Returns optimized ast (if optimized then returns a copy of it)
	local function optimizeAstPass1(currentAst)
		if not currentAst.children then
			return currentAst
		end

		---@type AstOperation
		local newAst = {
			children = {},
			id = currentAst.id,
			x = currentAst.x,
			y = currentAst.y,
			z = currentAst.z,
		}

		---@type Right | Left | Add | Sub | nil
		local previousAstId = nil
		---@type integer
		local times = 0 -- How many times this ast has been sawn

		for k, v in ipairs(currentAst.children) do
			if v.id < 0 or v.id > 3 then
				if times > 0 then
					addToAst(newAst, {
						id = pass1LookupId[previousAstId],
						x = times,
					})
					previousAstId = nil
					timesFolded = timesFolded + times
					times = 0
				end
				addToAst(newAst, optimizeAstPass1(v))
			else
				if not previousAstId then
					previousAstId = v.id --[[@as 0|1|2|3]]
				end

				if v.id == previousAstId then
					times = times + 1
				else
					if times > 0 then
						addToAst(newAst, {
							id = pass1LookupId[previousAstId],
							x = times,
						})
						timesFolded = timesFolded + times
					end
					previousAstId = v.id --[[@as 0|1|2|3]]
					times = 1
				end
			end
		end

		if times > 0 then
			addToAst(newAst, {
				id = pass1LookupId[previousAstId],
				x = times,
			})
		end

		return newAst
	end

	if O >= 1 then
		ast = optimizeAstPass1(ast)
		if DEV or SHOW_STATS then
			print("Finished folding optimization pass, folded", timesFolded, "operations!")
			if DEV then
				renderAst()
			end
		end
	end
end

---2nd pass

do
	local pass2LookupId = {
		--1st pass
		[0] = 15,
		[1] = 16,
		[2] = 14,
		[3] = 14,
		---2nd pass
		[9] = 15,
		[10] = 16,
		[11] = 14,
		[12] = 14,
	}

	local simpleOperations = {
		[0] = true,
		[1] = true,
		[2] = true,
		[3] = true,
		---1st pass
		[9] = true,
		[10] = true,
		[11] = true,
		[12] = true,
	}
	local timesOptimized = 0

	---@param currentAst AstOperation
	---@return AstOperation returns copy if it was optimized
	local function optimizeAstPass2(currentAst)
		if not currentAst.children then
			return currentAst
		end

		---@type AstOperation
		local newAst = {
			children = {},
			id = currentAst.id,
			x = currentAst.x,
			y = currentAst.y,
			z = currentAst.z,
		}

		for k, v in ipairs(currentAst.children) do
			if v.id == 4 then
				if #v.children == 1 and pass2LookupId[v.children[1].id] then -- Free/ScanLeft/ScanRight
					timesOptimized = timesOptimized + 1
					if pass2LookupId[v.children[1].id] == 14 then
						addToAst(newAst, {
							id = pass2LookupId[v.children[1].id],
						})
					else
						addToAst(newAst, {
							id = pass2LookupId[v.children[1].id],
							x = v.children[1].x or 1,
						})
					end
				else
					local hasComplex = false
					for _, v1 in ipairs(v.children) do
						if not simpleOperations[v1.id] then
							hasComplex = true
							break
						end
					end

					if hasComplex then --Has complex operations, cant break into simple multiplication...
						addToAst(newAst, optimizeAstPass2(v))
					else
						---@type {[integer] : integer} # k - cell relative index, v - multiplication value
						local manipulatedMap = {}

						local index = 0
						for _, v1 in ipairs(v.children) do
							if v1.id == 0 or v1.id == 9 then
								index = index + (v1.x or 1)
							elseif v1.id == 1 or v1.id == 10 then
								index = index - (v1.x or 1)
							elseif v1.id == 2 or v1.id == 11 then
								manipulatedMap[index] = (manipulatedMap[index] or 0) + (v1.x or 1)
							else
								manipulatedMap[index] = (manipulatedMap[index] or 0) - (v1.x or 1)
							end
						end

						if manipulatedMap[0] and manipulatedMap[0] == -1 and index == 0 then -- Then it is considered as a proper multiplication loop
							manipulatedMap[0] = nil

							local ifStatement = { id = 31, children = {} } --If statement for SAFE MODE

							local toAdd = SAFE_MODE and ifStatement or newAst

							for k1, v1 in pairs(manipulatedMap) do
								addToAst(toAdd, { -- MultXY
									id = 13,
									x = v1,
									y = k1,
								})
							end

							addToAst(toAdd, { -- Free current cell
								id = 14,
							})

							if SAFE_MODE then
								addToAst(newAst, ifStatement)
							end

							timesOptimized = timesOptimized + 1
						else
							addToAst(newAst, optimizeAstPass2(v))
						end
					end
				end
			else
				addToAst(newAst, optimizeAstPass2(v))
			end
		end

		return newAst
	end

	if O >= 2 then
		ast = optimizeAstPass2(ast)

		if DEV or SHOW_STATS then
			print("Finished cycle folding optimization pass, optimized", timesOptimized, "operations!")
			if DEV then
				renderAst()
			end
		end
	end
end

--3rd pass (For/If loops)

do
	local timesOptimized = 0

	---@param currentAst AstOperation
	---@return AstOperation
	local function optimizeAstPass3(currentAst)
		if not currentAst.children then
			return currentAst
		end

		---@type AstOperation
		local newAst = {
			children = {},
			id = currentAst.id,
			x = currentAst.x,
			y = currentAst.y,
			z = currentAst.z,
		}

		for k, v in ipairs(currentAst.children) do
			if v.id == 4 and v.children then
				---@type {[integer] : boolean?}
				local multipliedMap = {}
				---@type {[integer] : true}
				local usedToMultiplyMap = {}
				---@type {[integer] : boolean?} # K - index, V - was it freed?
				local freedMap = {}
				---@type {[integer] : integer?} # K - index, V - delta manipulation (same as in pass 2)
				local manipulatedMap = {}

				---@type {[0] : AstOperation, [1] : integer, [2] : integer?}[] # [0] : Ast, [1] : current index, [2] : index to multiply to
				local queue = {}

				----If value was freed
				---Remove manipulatedMap/multipliedMap
				---Allows us to know if value == 0 by the end of a cycle

				---The core idea:
				----If index[0] was freed and wasnt manipulated/multiplied
				---It means that it's a if buffer[index] then ... end
				----If index[0] was manipulated by -X (-X < 0) (and not freed/multiplied)
				---It means it's a for i = 0, buffer[index], X do ... end

				local index = 0
				local hasGoodChildren = true
				for k1, v1 in ipairs(v.children) do
					queue[#queue + 1] = { [0] = v1, [1] = index, [2] = v1.id == 13 and index + v1.y or nil }

					if v1.id == 0 or v1.id == 9 then --Right
						index = index + (v1.x or 1)
					elseif v1.id == 1 or v1.id == 10 then --Left
						index = index - (v1.x or 1)
					elseif v1.id == 2 or v1.id == 11 then --Add
						manipulatedMap[index] = (manipulatedMap[index] or 0) + (v1.x or 1)
					elseif v1.id == 3 or v1.id == 12 then --Sub
						manipulatedMap[index] = (manipulatedMap[index] or 0) - (v1.x or 1)
					elseif v1.id == 13 then -- Mult
						local output = index + v1.y

						multipliedMap[output] = true
					elseif v1.id == 14 then
						multipliedMap[index] = nil
						multipliedMap[index] = nil
						manipulatedMap[index] = nil

						freedMap[index] = true
					elseif v1.id ~= 7 then
						hasGoodChildren = false
						break
					end
				end

				if hasGoodChildren and index == 0 then
					if freedMap[0] and not manipulatedMap[0] and not multipliedMap[0] and not usedToMultiplyMap[0] then ---Then it's probably a If loop
						local newAst1 = {
							id = 31,
							children = {},
						}

						for k1, v1 in ipairs(queue) do -- We do queue to check on what index AST operation is working on
							if not (v1[0].id == 14 and v1[1] == 0) then -- We actually dont need to use Free on index[0] since its not needed
								addToAst(newAst1, v1[0])
							end
						end

						addToAst(newAst, newAst1)
						addToAst(newAst, { id = 14 })
						timesOptimized = timesOptimized + 1
					elseif manipulatedMap[0] and manipulatedMap[0] < 0 and not freedMap[0] and not multipliedMap[0] then ---Then it's probably a FOR loop
						local newAst1 = {
							id = 30,
							x = -manipulatedMap[0],
							children = {},
						}

						for k1, v1 in ipairs(queue) do
							if
								not (
									(v1[0].id == 2 or v1[0].id == 3 or v1[0].id == 11 or v1[0].id == 12)
									and v1[1] == 0
								)
							then
								addToAst(newAst1, v1[0])
							end
						end

						addToAst(newAst, newAst1)
						addToAst(newAst, { id = 14 })
						timesOptimized = timesOptimized + 1
					else --Cant create any optimized loop out of it
						addToAst(newAst, optimizeAstPass3(v))
					end
				else
					addToAst(newAst, optimizeAstPass3(v))
				end
			else
				addToAst(newAst, optimizeAstPass3(v))
			end
		end

		return newAst
	end

	if O >= 3 then
		ast = optimizeAstPass3(ast)

		if DEV or SHOW_STATS then
			print("Finished If/For constructs optimization pass, optimized", timesOptimized, "cycles")
		end
	end
end

---4th (previously 3rd) pass

do
	---@type {[integer] : fun(currentAst : AstOperation) : integer}
	local movingOperations = {
		[0] = function(ast)
			return 1
		end,
		[1] = function(currentAst)
			return -1
		end,
		[9] = function(currentAst)
			return currentAst.x
		end,
		[10] = function(currentAst)
			return -currentAst.x
		end,
	}

	local pass4LookupId = {
		[2] = 25,
		[3] = 26,
		[6] = 23,
		[7] = 24,
		[11] = 17,
		[12] = 18,
		[13] = 19,
		[14] = 20,
		[15] = 21,
		[16] = 22,
	}

	local offsetOperations = {
		[15] = true,
		[16] = true,
	}

	---@param astOperation AstOperation
	---@param offset integer
	---@return AstOperation
	local function copyAst(astOperation, offset)
		---@type AstOperation
		local newAst = {
			id = pass4LookupId[astOperation.id],
			x = astOperation.x or offset,
			y = astOperation.y or (astOperation.x and offset or nil),
			z = astOperation.z or (astOperation.y and astOperation.x and offset or nil),
		}

		return newAst
	end

	local timesOptimized = 0

	---@param currentAst AstOperation
	---@return AstOperation
	local function optimizeAstPass4(currentAst)
		if not currentAst.children then
			return currentAst
		end

		---@type AstOperation
		local newAst = {
			children = {},
			id = currentAst.id,
			x = currentAst.x,
			y = currentAst.y,
			z = currentAst.z,
		}

		local index = 0

		for k, v in ipairs(currentAst.children) do
			if movingOperations[v.id] then
				index = index + movingOperations[v.id](v)
				timesOptimized = timesOptimized + 1
			elseif v.children then
				if index ~= 0 then
					addToAst(newAst, {
						id = index > 0 and 9 or 10,
						x = math.abs(index),
					})
					timesOptimized = timesOptimized - 1
					index = 0
				end

				addToAst(newAst, optimizeAstPass4(v))
			elseif pass4LookupId[v.id] then
				if index == 0 then
					addToAst(newAst, v)
				else
					addToAst(newAst, copyAst(v, index))
				end

				if offsetOperations[v.id] then
					index = 0 --Index buffer has been moved already, we cant offset next stuff because of it!
				end
			else
				if index ~= 0 then
					addToAst(newAst, {
						id = index > 0 and 9 or 10,
						x = math.abs(index),
					})
					timesOptimized = timesOptimized - 1
					index = 0
				end

				addToAst(newAst, optimizeAstPass4(v))
			end
		end

		if index ~= 0 and currentAst.id ~= 8 then
			addToAst(newAst, {
				id = index > 0 and 9 or 10,
				x = math.abs(index),
				timesOptimized = timesOptimized - 1,
			})
			index = 0
		end

		return newAst
	end

	if O >= 4 then
		ast = optimizeAstPass4(ast)
		if DEV or SHOW_STATS then
			print("Finished offsetting optimization pass!", timesOptimized, "of operations were folded!")
			if DEV then
				renderAst()
			end
		end
	end
end

---@param astOperation AstOperation
---@return integer offset
local function findOffset(astOperation)
	---TODO: make it work with RepeatedXXX
	return (astOperation.id >= 17 and astOperation.id <= 26) and (astOperation.z or astOperation.y or astOperation.x)
		or 0 --Hacky way, but okay?
end

---5th pass
---Free(Y)->Mult(from X to Y)....Mult(From Y to X)....Free(Y) -> Free(Y)...Mult(X)

do
	---They act like a cycle, we CANT predict what they will do
	local movingCells = {
		[15] = true,
		[16] = true,
		[21] = true,
		[22] = true,
	}

	local shrinkedTimes = 0

	---@param currentAst AstOperation
	---@return AstOperation
	local function optimizeAstPass5(currentAst)
		if not currentAst.children then
			return currentAst
		end

		---@type AstOperation
		local newAst = {
			children = {},
			id = currentAst.id,
			x = currentAst.x,
			y = currentAst.y,
			z = currentAst.z,
		}

		---@type {[integer] : boolean} # Map of cells that are 0 and we know it
		local freedMap = {}
		---@type {[integer] : integer} -[K] - dest, [V] - source
		local copyMap = {} -- Map of cells that was copied from what cell

		---Each index (offset) reset - we do a new iteration
		---This is done so we can shrink mults (withour freeing) even if there is moving iteration (aka)
		local iteration = 1

		---@type {[integer] : {[integer] : integer}}
		local shrinkSourceMap = { {} }
		---@type {[integer] : {[integer] : integer}}
		local shrinkDestMap = { {} }
		for k, v in ipairs(currentAst.children) do
			if v.children or movingCells[v.id] then -- We CANT guarantee that cells affected by this map are NOT affected by this AST
				---Moving ASTs are cycles too, but act like as an linear instruction
				freedMap = {}
				copyMap = {}
				iteration = iteration + 1
				shrinkDestMap[iteration] = {}
				shrinkSourceMap[iteration] = {}
			elseif v.id == 14 or v.id == 20 then
				local index = v.x or 0
				freedMap[index] = true
				copyMap[index] = nil
			elseif v.id == 13 or v.id == 19 and v.x == 1 then
				local output = v.y + (v.z or 0)
				---We can basically say output is a copy of source
				if copyMap[v.z or 0] == output then -- We totally know those 2 can be shrinked
					shrinkDestMap[iteration][v.z or 0] = output
					shrinkSourceMap[iteration][output] = v.z or 0
				elseif freedMap[output] or currentAst.id == 8 and iteration == 1 then
					copyMap[output] = v.z or 0
				else
					copyMap[output] = nil
					freedMap[output] = nil
				end
			elseif v.id ~= 7 and v.id ~= 24 then
				local index = findOffset(v)
				freedMap[index] = nil
				copyMap[index] = nil
			end
		end

		---@type {[integer] : {[integer] : true}} # After this we know we already used dest copy to original, so we can remove afterward free (only 1 free)
		local shrinkUsed = {}
		for i = 1, iteration do
			shrinkUsed[i] = {}
		end

		iteration = 1

		for k, v in ipairs(currentAst.children) do
			if v.children or movingCells[v.id] then
				iteration = iteration + 1
				addToAst(newAst, optimizeAstPass5(v))
			elseif v.id == 13 or v.id == 19 and v.x == 1 then
				local from = v.z or 0
				local to = v.y + from

				if shrinkDestMap[iteration][to] == from or shrinkSourceMap[iteration][to] == from then
					--We can remove 1 FREE
					shrinkedTimes = shrinkedTimes + 1
					shrinkUsed[iteration][from] = true
				else
					if shrinkDestMap[iteration][from] then
						v = {
							id = shrinkDestMap[iteration][from] == 0 and 13 or 19,
							x = v.x,
							y = v.y + (from - shrinkDestMap[iteration][from]),
							z = shrinkDestMap[iteration][from] == 0 and nil or shrinkDestMap[iteration][from],
						}
					end
					addToAst(newAst, optimizeAstPass5(v))
				end
			elseif v.id == 14 or v.id == 20 then
				local index = v.x or 0

				if shrinkUsed[iteration][index] then
					shrinkedTimes = shrinkedTimes + 1
					shrinkUsed[iteration][index] = nil -- We shrinked Free
				else
					addToAst(newAst, optimizeAstPass5(v))
				end
			else
				addToAst(newAst, optimizeAstPass5(v))
			end
		end

		return newAst
	end

	if O >= 5 and USE_UNSTABLE then
		ast = optimizeAstPass5(ast)
		if DEV or SHOW_STATS then
			print("Finished copy shrinking pass, shrinked", shrinkedTimes, "operations")
		end
	end
end

--6th pass
--Repeat shrinking pass
do
	---They act like a cycle, we CANT predict what they will do
	local movingCells = {
		[15] = true,
		[16] = true,
		[21] = true,
		[22] = true,
	}

	local pass6LookupId = {
		[14] = 32, -- Free
		[20] = 32, -- FreeX

		[11] = 33,
		[17] = 33,

		[12] = 34,
		[18] = 34,

		[13] = 35,
		[19] = 35,
	}

	---@type {[integer] : 1 | 2 | 3 |4} #X,Y,Z - 1, 2, 3, 4 indexes to lookup
	local pass6LookupIndex = {
		[32] = 2,
		[33] = 3,
		[34] = 3,
		[35] = 4,
	}

	local timesShrinked = 0

	---@param copyAstFrom AstOperation
	---@param times integer
	---@param step integer
	---@param initialIndex integer
	---@return AstOperation
	local function copyAst(copyAstFrom, times, step, initialIndex)
		local newAst = {
			id = pass6LookupId[copyAstFrom.id],
			x = copyAstFrom.x,
			y = copyAstFrom.y,
			z = copyAstFrom.z,
			--- Now W cuz repeated ops only use that!
		}

		local index = pass6LookupIndex[newAst.id]

		if index == 1 then -- Not used though
			newAst.x = times
			newAst.y = step
		elseif index == 2 then -- Free
			newAst.x = initialIndex
			newAst.y = times
			newAst.z = step
		elseif index == 3 then
			newAst.x = newAst.x or 0
			newAst.y = initialIndex
			newAst.z = times
			newAst.w = step
		else
			newAst.x = newAst.x or 0
			newAst.y = newAst.y or 0
			newAst.z = initialIndex
			newAst.w = times --For MultXYZW only
		end

		return newAst
	end

	---@param currentAst AstOperation
	---@param prevAst AstOperation
	---@return boolean # success
	local function checkAsts(currentAst, prevAst)
		if pass6LookupId[currentAst.id] == 35 then --Both are mults
			return currentAst.x == prevAst.x and currentAst.z == prevAst.z
		elseif pass6LookupId[currentAst.id] ~= 32 then --Sub/Add
			return currentAst.x == prevAst.x
		end

		return true
	end

	---@param currentAst AstOperation
	---@param prevAst AstOperation
	---@param steps integer
	---@return boolean # success
	local function checkOffsets(currentAst, prevAst, steps)
		if pass6LookupId[currentAst.id] == 35 then --Both are mults
			return currentAst.y - prevAst.y == 1
		end

		return findOffset(currentAst) - findOffset(prevAst) == steps
	end

	---@param count integer
	---@param prevAst AstOperation?
	---@param step integer?
	---@param initialIndex integer?
	---@param newAst AstOperation
	---@param currentAst AstOperation
	---@param k integer
	local function addNewAst(count, prevAst, step, initialIndex, newAst, currentAst, k)
		if
			prevAst
			and count
				>= (pass6LookupId[prevAst.id] == 32 and math.abs(step or 0) == 1 and MIN_COUNT_TO_MEMSET or MIN_COUNT_TO_SHRINK)
		then
			addToAst(newAst, copyAst(prevAst, count, step or 1, initialIndex or 0))
			timesShrinked = timesShrinked + count
		elseif prevAst then
			for i = count, 1, -1 do
				addToAst(newAst, currentAst.children[k - i])
			end
		end
	end

	---@param currentAst AstOperation
	---@return AstOperation
	local function optimizeAstPass6(currentAst)
		if not currentAst.children then
			return currentAst
		end

		---@type AstOperation
		local newAst = {
			children = {},
			id = currentAst.id,
			x = currentAst.x,
			y = currentAst.y,
			z = currentAst.z,
		}

		---@type AstOperation?
		local prevAst = nil
		---@type integer?
		local step
		---@type integer
		local count = 0
		---@type integer?
		local initialIndex

		for k, v in ipairs(currentAst.children) do
			if movingCells[v.id] or v.children then --Cant predict, bad
				addNewAst(count, prevAst, step, initialIndex, newAst, currentAst, k)

				addToAst(newAst, optimizeAstPass6(v))

				prevAst = nil
				step = nil
				initialIndex = nil
				count = 0
			elseif prevAst and pass6LookupId[prevAst.id] ~= pass6LookupId[v.id] then -- Different converted ASTs id, BAD
				addNewAst(count, prevAst, step, initialIndex, newAst, currentAst, k)

				if pass6LookupId[v.id] then
					prevAst = v
					step = pass6LookupId[v.id] == 35 and 0 or nil
					count = 1
					initialIndex = findOffset(v)
				else
					prevAst = nil
					step = nil
					count = 0
					initialIndex = nil

					addToAst(newAst, optimizeAstPass6(v))
				end
			elseif pass6LookupId[v.id] then
				if not initialIndex then
					initialIndex = findOffset(v)
				end

				if not prevAst then
					if pass6LookupId[v.id] == 35 then
						step = 0
					end
					count = 1
					initialIndex = findOffset(v)
				elseif not step and checkAsts(v, prevAst) then
					step = pass6LookupId[v.id] == 35 and 1 or findOffset(v) - findOffset(prevAst)
					count = 2
				elseif step and (not checkOffsets(v, prevAst, step or 1) or not checkAsts(prevAst, v)) then --Different step, but still can batch
					addNewAst(count, prevAst, step, initialIndex, newAst, currentAst, k)

					count = 1
					initialIndex = findOffset(v)
					step = pass6LookupId[v.id] == 35 and 0 or nil
				elseif not step and not checkAsts(v, prevAst) then
					addNewAst(count, prevAst, step, initialIndex, newAst, currentAst, k)

					count = 1
					initialIndex = findOffset(v)
					step = pass6LookupId[v.id] == 35 and 0 or nil
				else
					count = count + 1
				end

				prevAst = v
			else -- Invalid AST, cant do shit
				addNewAst(count, prevAst, step, initialIndex, newAst, currentAst, k)

				prevAst = nil
				step = nil
				initialIndex = nil
				count = 0

				addToAst(newAst, optimizeAstPass6(v))
			end
		end

		addNewAst(count, prevAst, step, initialIndex, newAst, currentAst, #currentAst.children + 1)

		return newAst
	end

	if O >= 6 then
		ast = optimizeAstPass6(ast)
		if DEV or SHOW_STATS then
			print("Finished repeat folding pass, folded", timesShrinked, "times")
		end
	end
end

--7th pass

do
	---*Ind -> Absolute position (not relative to the current AST)
	---*Rel -> Relative position (relative to the current AST, needs to be offsetted to get absolute)
	---@alias Match {[1]: Operation|{[Operation] : true}, children : Match[]?, childrenShareIndexQueue : boolean?, x: integer?, y : integer?, z: integer?, xInd : integer?, yInd : integer?, zInd : integer?, xRel : integer?, yRel : integer?, zRel : integer?}

	---@class Pattern
	---@field astBuilder fun(asts:AstOperation[]) : AstOperation[]
	---@field [integer] Match
	---@field name string
	---@field times integer

	---@param astBuilder fun(asts:AstOperation[]) : AstOperation
	---@param ... Match
	---@return Pattern
	local function createPattern(astBuilder, name, ...)
		return { astBuilder = astBuilder, name = name, times = 0, ... }
	end
	---How patterns work?
	--- pattern { [patternId:integer] = { {operation, x=x, y=y, z=z, xInd=xInd...}, ... ]
	---X,Y,Z keys assign that this operation must contain these specific values
	---XInd,YInd,ZInd means that those numbers mean that those indexes SHOULD allign (in absolute terms, aka no offsetting them) to the same index (meaning it can be any value if offseted, but be the same value without offsets)
	---XRel,YRel,ZRel same but needs to be offsetted to the current ast offset
	---@type Pattern[]
	local patterns = {}

	table.sort(patterns, function(a, b) -- Shorter matches first, then going to longer matches (should be faster)
		return #a < #b
	end)

	---@param asts AstOperation[]
	---@param matches Match[]
	---@param indexQueue {[integer] : integer}?
	---@return boolean matched
	---@return boolean? full
	local function matchInternalAst(asts, matches, indexQueue)
		indexQueue = indexQueue or {}

		for matchNumber, match in ipairs(matches) do
			if matchNumber > #asts then
				return true, false
			end

			local currentAst = asts[matchNumber]

			if type(match[1]) == "table" then
				if not match[1][currentAst.id] then
					return false
				end
			else
				if match[1] ~= currentAst.id then
					return false
				end
			end

			if match.x and match.x ~= currentAst.x then
				return false
			elseif match.y and match.y ~= currentAst.y then
				return false
			elseif match.z and match.z ~= currentAst.z then
				return false
			end

			if match.xInd then
				local absOffset = currentAst.x or 0
				if not indexQueue[match.xInd] then
					indexQueue[match.xInd] = absOffset
				end

				if indexQueue[match.xInd] and indexQueue[match.xInd] ~= absOffset then
					return false
				end
			end

			if match.yInd then
				local absOffset = currentAst.y or 0
				if not indexQueue[match.yInd] then
					indexQueue[match.yInd] = absOffset
				end

				if indexQueue[match.yInd] and indexQueue[match.yInd] ~= absOffset then
					return false
				end
			end

			if match.zInd then
				local absOffset = currentAst.z or 0
				if not indexQueue[match.zInd] then
					indexQueue[match.zInd] = absOffset
				end

				if indexQueue[match.zInd] and indexQueue[match.zInd] ~= absOffset then
					return false
				end
			end

			if match.xRel then
				local absOffset = (currentAst.x or 0) + findOffset(currentAst)
				if not indexQueue[match.xRel] then
					indexQueue[match.xRel] = absOffset
				end

				if indexQueue[match.xRel] and indexQueue[match.xRel] ~= absOffset then
					return false
				end
			end

			if match.yRel then
				local absOffset = (currentAst.y or 0) + findOffset(currentAst)
				if not indexQueue[match.yRel] then
					indexQueue[match.yRel] = absOffset
				end

				if indexQueue[match.yRel] and indexQueue[match.yRel] ~= absOffset then
					return false
				end
			end

			if match.zRel then
				local absOffset = (currentAst.z or 0) + findOffset(currentAst)
				if not indexQueue[match.zRel] then
					indexQueue[match.zRel] = absOffset
				end

				if indexQueue[match.zRel] and indexQueue[match.zRel] ~= absOffset then
					return false
				end
			end

			if match.children then
				if not match.children then
					return false, false
				end

				local _, full = matchInternalAst(
					currentAst.children,
					match.children,
					match.childrenShareIndexQueue and indexQueue or nil
				)

				if not full then
					return false, false
				end
			end
		end

		return true, true
	end

	---@param asts AstOperation[]
	---@return integer? First founded matched pattern, nil if not found
	---@return boolean? If match is full
	local function matchAst(asts)
		for patternId, pattern in ipairs(patterns) do
			---@type {[integer] : integer}

			local matched, full = matchInternalAst(asts, pattern)

			if full then
				return patternId, true
			elseif matched then
				return patternId, false
			end
		end

		return nil
	end

	---@param currentAst AstOperation
	---@return AstOperation
	local function optimizeAstPass7(currentAst)
		if not currentAst.children then
			return currentAst
		end

		---@type AstOperation
		local newAst = {
			children = {},
			id = currentAst.id,
			x = currentAst.x,
			y = currentAst.y,
			z = currentAst.z,
		}

		---@type AstOperation[]
		local astMatchQueue = {} --Queue of successfully matched ASTs

		for k, v in ipairs(currentAst.children) do
			astMatchQueue[#astMatchQueue + 1] = v

			if DEV then
				print("====Matched queue", dump(astMatchQueue))
			end
			local id, full = matchAst(astMatchQueue)
			if DEV then
				print("====result is", patterns[id] and patterns[id].name or id, full)
			end
			if id and full then
				local buildedAsts = patterns[id].astBuilder(astMatchQueue)
				patterns[id].times = patterns[id].times + 1

				for k1, v1 in ipairs(buildedAsts) do
					addToAst(newAst, optimizeAstPass7(v1))
				end
				astMatchQueue = {}
			elseif not id then
				astMatchQueue[#astMatchQueue] = nil

				for k1, v1 in ipairs(astMatchQueue) do
					addToAst(newAst, optimizeAstPass7(v1))
				end

				astMatchQueue = { v }
				local id2, full2 = matchAst(astMatchQueue)
				if id2 and full then
					local buildedAsts = patterns[id].astBuilder(astMatchQueue)
					patterns[id].times = patterns[id].times + 1

					for k1, v1 in ipairs(buildedAsts) do
						addToAst(newAst, optimizeAstPass7(v1))
					end
					astMatchQueue = {}
				elseif not id2 then
					addToAst(newAst, optimizeAstPass7(v))
					astMatchQueue = {}
				end
			end
		end

		for k, v in ipairs(astMatchQueue) do
			addToAst(newAst, optimizeAstPass7(v))
		end

		return newAst
	end

	if O >= 7 then
		ast = optimizeAstPass7(ast)
		if DEV or SHOW_STATS then
			print("Finished pattern matching pass of optimization")
			print("-----PATTERN-STATS------")
			table.sort(patterns, function(a, b)
				return a.name > b.name
			end)
			for k, v in ipairs(patterns) do
				print(v.name, v.times)
			end
			print("-----------------------")
		end
	end
end

---Pass 7 (X linear instructions -> for i = 0, X-1 do LINEAR_INSTRUCTION end)
do
end

---Compilation

do
	local bufferCreation = FFI_SAFE_MODE
			and string.format(
				[[local bufferInternal = ffi.new('uint8_t[%u]')
local buffer = setmetatable({}, {__index = function(_, key)
    if key < 0 then
        error('We have encountered error on indexing! Key < 0')
        key = 0
    elseif key >= %u then
        error('We have encountered error on indexing! Key > Array size')
        key = %u
    end
    return bufferInternal[key]
end, __newindex = function(_, key, value)
    if key < 0 then
        error('We have encountered error on setting! Key < 0')
        key = 0
    elseif key >= %u then
        error('We have encountered error on setting! Key > Array size')
        key = %u
    end
    bufferInternal[key] = value
end})]],
				BUFFER_SIZE,
				BUFFER_SIZE,
				BUFFER_SIZE,
				BUFFER_SIZE,
				BUFFER_SIZE
			)
		or string.format(
			[[local fullBuffer = ffi.new('uint8_t[%u]')
local buffer = ffi.cast('uint8_t*', fullBuffer+%u)
local bufferInternal = buffer]],
			BUFFER_SIZE + BUFFER_PADDING * 2,
			BUFFER_PADDING
		)

	local payload = FFI
			and FFI_USE_RAYLIB
			and string.format(
				[=[
local ffi = require('ffi')
ffi.cdef([[
    void *memchr(const void *s, int c, size_t n);
    void *memrchr(const void *s, int c, size_t n);
    void* memset( void* dest, int ch, size_t count );

    typedef struct Color {
        unsigned char r;        // Color red value
        unsigned char g;        // Color green value
        unsigned char b;        // Color blue value
        unsigned char a;        // Color alpha value
    } Color;

    typedef struct Image {
        void *data;             // Image raw data
        int width;              // Image base width
        int height;             // Image base height
        int mipmaps;            // Mipmap levels, 1 by default
        int format;             // Data format (PixelFormat type)
    } Image;

    // Texture, tex data stored in GPU memory (VRAM)
    typedef struct Texture {
        unsigned int id;        // OpenGL texture id
        int width;              // Texture base width
        int height;             // Texture base height
        int mipmaps;            // Mipmap levels, 1 by default
        int format;             // Data format (PixelFormat type)
    } Texture;

    typedef Texture Texture2D;

    // Rectangle, 4 components
    typedef struct Rectangle {
        float x;                // Rectangle top-left corner position x
        float y;                // Rectangle top-left corner position y
        float width;            // Rectangle width
        float height;           // Rectangle height
    } Rectangle;

    typedef Rectangle Rect;

    typedef struct Vector2 {
        float x;
        float y;
    } Vector2;

    void InitWindow(int width, int height, const char *title);
    void InitAudioDevice(void);
    void SetWindowTitle(const char *title);
    void CloseWindow(void);
    void CloseAudioDevice(void);
    bool WindowShouldClose(void);
    void BeginDrawing(void);
    void EndDrawing(void);
    void ClearBackground(Color color);
    Texture2D LoadTextureFromImage(Image image);
    void UpdateTexture(Texture2D texture, const void *pixels);
    void DrawTexturePro(Texture2D texture, Rectangle source, Rectangle dest, Vector2 origin, float rotation, Color tint);
    void SetTargetFPS(int fps);
    int GetFPS(void);
    bool IsKeyDown(int key);
]])
%s
local index = 0
local C = ffi.C

------------

local rl = ffi.load("raylib")

local screenWidth = 640
local screenHeight = 480

local image = ffi.new("Image")
image.data = bufferInternal
image.width = 16
image.height = 16
image.mipmaps = 1
image.format = 1

rl.InitWindow(screenWidth, screenHeight, "bf16.lua")
rl.InitAudioDevice()

local texture = rl.LoadTextureFromImage(image)
local white = ffi.new("Color", 255, 255, 255, 255)

local frameWidth = texture.width
local frameHeight = texture.height

local sourceRect = ffi.new("Rectangle")
sourceRect.x = 0
sourceRect.y = 0
sourceRect.width = frameWidth
sourceRect.height = frameHeight

local destRect = ffi.new("Rect")
destRect.x = 0
destRect.y = 0
destRect.width = screenWidth
destRect.height = screenHeight

local zero = ffi.new("Vector2")
zero.x = 0
zero.y = 0

rl.SetTargetFPS(60)
rl.BeginDrawing()

local count = 0

local function swapBuffers()
    rl.UpdateTexture(texture, bufferInternal)
    rl.DrawTexturePro(texture, sourceRect, destRect, zero, 0, white)

    rl.EndDrawing()

    rl.SetWindowTitle(string.format("bf16.lua (fps : %%u)", rl.GetFPS()))

    if rl.WindowShouldClose() then
        rl.CloseWindow()
        rl.CloseAudioDevice()
        return true
    end

    rl.BeginDrawing()
    rl.ClearBackground(white)

    return false
end

local function read(offset)

	buffer[index+(offset or 0)] = bit.bor(
		rl.IsKeyDown(90) and 0x80 or 0, --Z
		rl.IsKeyDown(88) and 0x40 or 0, --X
		rl.IsKeyDown(259) and 0x20 or 0, --Backspace
		rl.IsKeyDown(32) and 0x10 or 0, --Space
		rl.IsKeyDown(265) and 0x08 or 0, --Up
		rl.IsKeyDown(264) and 0x04 or 0, --Down
		rl.IsKeyDown(263) and 0x02 or 0, --Left
		rl.IsKeyDown(262) and 0x01 or 0 --Right
	)
end

if jit then
    jit.opt.start("loopunroll=100", "hotloop=10")
end
]=],
				bufferCreation
			)
		or FFI and string.format(
			[[
local ffi = require('ffi')
ffi.cdef('int putchar( int ch );\nint getchar();\nvoid *memchr(const void *s, int c, size_t n);\nvoid *memrchr(const void *s, int c, size_t n);void* memset( void* dest, int ch, size_t count );')
%s
local index = 0
local C = ffi.C
local write = C.putchar
local read = C.getchar

if jit then
    jit.opt.start("loopunroll=100", "hotloop=10")
end
]],
			bufferCreation
		)
		or string.format(
			[[local buffer = {}
for i = 0 - %u, %u do
    buffer[i] = 0
end
local index = 0
local write = io.write
local char = string.char
local byte = string.byte
local read = io.read
local tostring = tostring
if jit then
    jit.opt.start("loopunroll=100", "hotloop=10")
end
-----------------]],
			BUFFER_PADDING,
			BUFFER_SIZE + BUFFER_PADDING * 2 - 1
		)

	local endPayload = FFI
			and FFI_USE_RAYLIB
			and [[while not rl.WindowShouldClose() do
	rl.BeginDrawing()
	rl.ClearBackground(white)
	rl.DrawTexturePro(texture, sourceRect, destRect, zero, 0, white)
	rl.EndDrawing()
end
rl.CloseWindow()
rl.CloseAudioDevice()]]
		or ""

	local idents = 0 -- Number of tabs for first line
	---@type {[Operation] : fun(currentAst : AstOperation) : string}
	local astCompileFuncs = {
		[0] = function(currentAst)
			return "index = index + 1 --Right"
		end,
		[1] = function(currentAst)
			return "index = index - 1 --Left"
		end,
		[2] = function(currentAst)
			return FFI and "buffer[index] = buffer[index] + 1 --Add" or "buffer[index] = (buffer[index] + 1)%256 --Add"
		end,
		[3] = function(currentAst)
			return FFI and "buffer[index] = buffer[index] - 1 --Sub" or "buffer[index] = (buffer[index] - 1)%256 --Sub"
		end,
		[4] = function(currentAst)
			return "while buffer[index] ~= 0 do --Start"
		end,
		[5] = function(currentAst)
			return "end --End"
		end,
		[6] = function(currentAst)
			return FFI and (FFI_USE_RAYLIB and "read() --Read" or "buffer[index] = C.getchar() --Read")
				or "buffer[index] = byte(read(1) or '\\0') --Read"
		end,
		[7] = function(currentAst)
			return FFI
					and (FFI_USE_RAYLIB and "if swapBuffers() then return end --Write" or "C.putchar(buffer[index]) --Write")
				or "write(char(buffer[index])) --Write"
		end,
		[8] = function(currentAst)
			return "--EntryPoint"
		end,
		[9] = function(currentAst)
			return string.format("index = index + %u --RightX", currentAst.x)
		end,
		[10] = function(currentAst)
			return string.format("index = index - %u --LeftX", currentAst.x)
		end,
		[11] = function(currentAst)
			return FFI and string.format("buffer[index] = buffer[index] + %u --AddX", currentAst.x)
				or string.format("buffer[index] = (buffer[index] + %u)%%256 --AddX", currentAst.x)
		end,
		[12] = function(currentAst)
			return FFI and string.format("buffer[index] = buffer[index] - %u --SubX", currentAst.x)
				or string.format("buffer[index] = (buffer[index] - %u)%%256 --SubX", currentAst.x)
		end,
		[13] = function(currentAst)
			return FFI
					and string.format(
						"buffer[index+(%i)] = buffer[index + (%i)] + buffer[index] * %i --MultXY",
						currentAst.y,
						currentAst.y,
						currentAst.x
					)
				or string.format(
					"buffer[index+(%i)] = (buffer[index + (%i)] + (buffer[index] or 0) * %i) %% 256 --MultXY",
					currentAst.y,
					currentAst.y,
					currentAst.x
				)
		end,
		[14] = function(currentAst)
			return "buffer[index] = 0 --Free"
		end,
		[15] = function(currentAst)
			return FFI
					and currentAst.x == 1
					and not FFI_SAFE_MODE
					and string.format(
						"index = ffi.cast('uint8_t*', C.memchr(bufferInternal+index, 0, %u - index )) - bufferInternal --ScanRightX",
						BUFFER_SIZE
					)
				or string.format(
					[[for i = 0, %u, %u do if buffer[index + i] == 0 then index = index + i break end end --ScanRightX]],
					SCAN_MAX_LENGTH,
					currentAst.x
				)
		end,
		[16] = function(currentAst)
			return FFI
					and currentAst.x == 1
					and not FFI_SAFE_MODE
					and "index = ffi.cast('uint8_t*', C.memrchr(bufferInternal, 0, index+1 )) - bufferInternal --ScanLeftX"
				or string.format(
					[[for i = 0, %u, %u do if buffer[index - i] == 0 then index = index - i break end end --ScanLeftX]],
					SCAN_MAX_LENGTH,
					currentAst.x
				)
		end,
		[17] = function(currentAst)
			return FFI
					and string.format(
						"buffer[index+(%i)] = buffer[index+(%i)] + %u --AddXY",
						currentAst.y,
						currentAst.y,
						currentAst.x
					)
				or string.format(
					"buffer[index+(%i)] = (buffer[index+(%i)] + %u)%%256 --AddXY",
					currentAst.y,
					currentAst.y,
					currentAst.x
				)
		end,
		[18] = function(currentAst)
			return FFI
					and string.format(
						"buffer[index+(%i)] = buffer[index+(%i)] - %u --SubXY",
						currentAst.y,
						currentAst.y,
						currentAst.x
					)
				or string.format(
					"buffer[index+(%i)] = (buffer[index+(%i)] - %u)%%256 --SubXY",
					currentAst.y,
					currentAst.y,
					currentAst.x
				)
		end,
		[19] = function(currentAst)
			return FFI
					and string.format(
						"buffer[index+(%i)] = buffer[index+(%i)] + buffer[index+(%i)] * %i --MultXYZ",
						currentAst.y + currentAst.z,
						currentAst.y + currentAst.z,
						currentAst.z,
						currentAst.x
					)
				or string.format(
					"buffer[index+(%i)] = (buffer[index+(%i)] + buffer[index+(%i)] * %i)%%256 --MultXYZ",
					currentAst.y + currentAst.z,
					currentAst.y + currentAst.z,
					currentAst.z,
					currentAst.x
				)
		end,
		[20] = function(currentAst)
			return string.format("buffer[index+(%i)] = 0 --FreeX", currentAst.x)
		end,
		[21] = function(currentAst)
			return FFI
					and currentAst.x == 1
					and not FFI_SAFE_MODE
					and string.format(
						"index = ffi.cast('uint8_t*', C.memchr(bufferInternal+index+(%i), 0, %u - (index+(%i)) )) - bufferInternal --ScanRightXY",
						currentAst.y,
						BUFFER_SIZE,
						currentAst.y
					)
				or string.format(
					[[for i = 0, %u, %u do if buffer[index + i + (%i)] == 0 then index = index + i + (%i) break end end --ScanRightXY]],
					SCAN_MAX_LENGTH,
					currentAst.x,
					currentAst.y,
					currentAst.y,
					currentAst.y
				)
		end,
		[22] = function(currentAst)
			return FFI
					and currentAst.x == 1
					and not FFI_SAFE_MODE
					and string.format(
						"index = ffi.cast('uint8_t*', C.memrchr(bufferInternal, 0, index+(%i)+1 )) - bufferInternal --ScanLeftXY",
						currentAst.y
					)
				or string.format(
					[[for i = 0, %u, %u do if buffer[index - i + (%i)] == 0 then index = index - i + (%i) break end end --ScanLeftXY]],
					SCAN_MAX_LENGTH,
					currentAst.x,
					currentAst.y,
					currentAst.y,
					currentAst.y
				)
		end,
		[23] = function(currentAst)
			return FFI
					and (FFI_USE_RAYLIB and string.format("read(%i) --ReadX", currentAst.x) or string.format(
						"buffer[index+(%i)] = C.getchar() --ReadX",
						currentAst.x
					))
				or string.format("buffer[index+(%i)] = byte(read(1) or '\\0') --ReadX", currentAst.x)
		end,
		[24] = function(currentAst)
			return FFI
					and (FFI_USE_RAYLIB and "if swapBuffers() then return end --WriteX" or string.format(
						"C.putchar(buffer[index+(%i)]) --WriteX",
						currentAst.x
					))
				or string.format("write(char(buffer[index+(%i)])) --WriteX", currentAst.x)
		end,
		[25] = function(currentAst)
			return FFI
					and string.format("buffer[index+(%i)] = buffer[index+(%i)] + 1 --AddY", currentAst.x, currentAst.x)
				or string.format(
					"buffer[index+(%i)] = (buffer[index+(%i)] + 1)%%256 --AddY",
					currentAst.x,
					currentAst.x
				)
		end,
		[26] = function(currentAst)
			return FFI
					and string.format("buffer[index+(%i)] = buffer[index+(%i)] - 1 --SubY", currentAst.x, currentAst.x)
				or string.format(
					"buffer[index+(%i)] = (buffer[index+(%i)] - 1)%%256 --SubY",
					currentAst.x,
					currentAst.x
				)
		end,
		[27] = function(currentAst)
			return string.format(
				"buffer[index+(%i)] = buffer[index+(%i)] --AssignXY",
				currentAst.y,
				currentAst.x + currentAst.y
			)
		end,
		[28] = function(currentAst)
			return FFI
					and string.format(
						"buffer[index+(%i)] = buffer[index+(%i)] + buffer[index+(%i)] --PlusXY",
						currentAst.y,
						currentAst.y,
						currentAst.x + currentAst.y
					)
				or string.format(
					"buffer[index+(%i)] = (buffer[index+(%i)] + buffer[index+(%i)])%%256 --PlusXY",
					currentAst.y,
					currentAst.y,
					currentAst.x + currentAst.y
				)
		end,
		[29] = function(currentAst)
			return FFI
					and string.format(
						"buffer[index+(%i)] = buffer[index+(%i)] * buffer[index+(%i)] --MultiplyXY",
						currentAst.y,
						currentAst.y,
						currentAst.y + currentAst.x
					)
				or string.format(
					"buffer[index+(%i)] = (buffer[index+(%i)] * buffer[index+(%i)])%%256 --MultiplyXY",
					currentAst.y,
					currentAst.y,
					currentAst.y + currentAst.x
				)
		end,
		[30] = function(currentAst) --ForX
			return string.format("for _ = 1, buffer[index], %u do --ForX", currentAst.x)
		end,
		[31] = function()
			return "if buffer[index] ~= 0 then --If"
		end,
		[32] = function(currentAst) --FreeeXYZ
			return FFI
					and math.abs(currentAst.z) == 1
					and not FFI_SAFE_MODE
					and string.format(
						"C.memset(bufferInternal+index+(%i), 0, %u )",
						currentAst.z < 0 and currentAst.x - currentAst.y or currentAst.x,
						currentAst.y
					)
				or string.format(
					"for i = 0, %u do buffer[index+(%i)+(i*%i)] = 0 end --FreeXYZ",
					currentAst.y - 1,
					currentAst.x,
					currentAst.z
				)
		end,
		[33] = function(currentAst)
			return string.format(
				FFI and "for i = 0, %u do buffer[index+(%i)+(i*%i)] = buffer[index+(%i)+(i*%i)] + %u end --AddXYZW"
					or "for i = 0, %u do buffer[index+(%i)+(i*%i)] = (buffer[index+(%i)+(i*%i)] + %u)%%256 end --AddXYZW",
				currentAst.z - 1,
				currentAst.y,
				currentAst.w,
				currentAst.y,
				currentAst.w,
				currentAst.x
			)
		end,
		[34] = function(currentAst)
			return string.format(
				FFI and "for i = 0, %u do buffer[index+(%i)+(i*%i)] = buffer[index+(%i)+(i*%i)] - %u end --SubXYZW"
					or "for i = 0, %u do buffer[index+(%i)+(i*%i)] = (buffer[index+(%i)+(i*%i)] - %u)%%256 end --SubXYZW",
				currentAst.z - 1,
				currentAst.y,
				currentAst.w,
				currentAst.y,
				currentAst.w,
				currentAst.x
			)
		end,
		[35] = function(currentAst)
			return string.format(
				FFI
						and "for i = 0, %u do buffer[index+(%i)-i] = buffer[index+(%i)-i] + buffer[index+(%i)] * %i end --MultXYZW"
					or "for i = 0, %u do buffer[index+(%i)-i] = (buffer[index+(%i)-i] + buffer[index+(%i)] * %i)%%256 end --MultXYZW",
				currentAst.w - 1,
				currentAst.y + currentAst.z,
				currentAst.y + currentAst.z,
				currentAst.z,
				currentAst.x
			)
		end,
	}

	---@param currentAst AstOperation
	---@param buffer string[]
	local function compileAst(currentAst, buffer)
		if currentAst.id ~= 8 then
			buffer[#buffer + 1] = string.rep("\t", idents) .. astCompileFuncs[currentAst.id](currentAst)
		end

		if currentAst.children and currentAst.id ~= 8 then
			idents = idents + 1
		end
		for k, v in ipairs(currentAst.children) do
			if v.children then
				compileAst(v, buffer)
			else
				buffer[#buffer + 1] = string.rep("\t", idents) .. astCompileFuncs[v.id](v)
			end
		end

		if currentAst.children and currentAst.id ~= 8 then
			idents = idents - 1
			buffer[#buffer + 1] = string.rep("\t", idents) .. astCompileFuncs[5](currentAst)
		end
	end

	if SHOW_CODE then
		local buffer = { payload }
		compileAst(ast, buffer)
		buffer[#buffer + 1] = endPayload

		-- local str = ""
		-- for k, v in ipairs(buffer) do
		-- 	str = str .. "\nprint([[" .. v .. "]], '==', " .. k .. ", index)\n" .. v
		-- end
		-- print(str)
		print(table.concat(buffer, "\n"))
	end
end
