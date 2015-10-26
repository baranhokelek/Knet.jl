using JLD, ArgParse, Knet

# opt: adam (beta1=0.9, beta2=0.999,epsilon=1e-08) batch=32, lr=0.001, gclip=5
# hidden: 128; no recurrent; biyofiz'de cpu'da 1 trn epoch 18 thread ile 258 sn. => 0.0371 char error
# hidden: 512; output layer'da recurrent connection; 1trn epoch: gpu'da 217 sn.; dev cerr (char error): 0.0256

# Knet speed: hidden:128, batch:32, non-recurr out, --fast 154 sec/epoch
# Knet speed: hidden:512, batch:32, non-recurr out, --fast 208 sec/epoch

# Set training parameters:

s = ArgParseSettings()
@add_arg_table s begin
    ("--hidden"; default=128; arg_type=Int)
    ("--lr"; default=0.001; arg_type=Float64) # WARNING: adam not implemented yet
    ("--batchsize"; default=32; arg_type=Int) # WARNING: I skip the leftovers
    ("--epochs"; default=1000; arg_type=Int)
    ("--gclip"; default=5.0; arg_type=Float64; help="model-wide gradient clip")
    ("--winit"; default="Gaussian(0,0.1)"; help="weight initialization")
    ("--fast"; action=:store_true; help="skip norm and loss calculations.")
    ("--gcheck"; default=0; arg_type=Int; help="gradient checking")
    ("--lossreport"; default=0; arg_type=Int; help="report training loss every n tokens")
    ("--seed"; default=42; arg_type=Int; help="random seed")
end
opts = parse_args(ARGS, s)
println(opts)
for (k,v) in opts; @eval ($(symbol(k))=$v); end
winit = eval(parse(winit))
seed > 0 && setseed(seed)

# Load data: (should we shuffle?)

@load "ner.jld"
@show map(size, (xtrn, ytrn, xdev, ydev))
trn = TagData(xtrn, ytrn; batchsize=batchsize, dense=true)
dev = TagData(xdev, ydev; batchsize=batchsize, dense=true)
@show maxtoken(xtrn)
@show nclass = maxtoken(ytrn)
flush(STDOUT)

# Construct peephole lstm model from http://arxiv.org/pdf/1308.0850.pdf pp.5
# TODO: faster lstm possible if I do it with a single wdot
# add2,wdot,bias defined in Knet/src/op/compound.jl

@knet function peeplstm(x; o...)
    input  = add3(x,h,c; o..., f=sigm)
    forget = add3(x,h,c; o..., f=sigm)
    newmem = add2(x,h; o..., f=tanh)
    ig = mul(input,newmem)
    fc = mul(forget,c)
    c  = add(ig,fc)
    output = add3(x,h,c; o..., f=sigm)
    tc = tanh(c)
    h  = mul(output,tc)
end

@knet function add3(x1, x2, x3; f=sigm, o...)
    y1 = wdot(x1; o...)
    y2 = wdot(x2; o...)
    y3 = wdot(x3; o...)
    z1 = add(y1,y2)
    z2 = add(z1,y3)
    z3 = bias(z2; o...)
    ou = f(z3; o...)
end

# Construct tagger model

# initialization ek:
# output layer'da sofmax kullanirsak:
# W=lasagne.init.GlorotUniform(gain=1.0) # aka Xavier initialization.
# b=lasagne.init.Constant(0.)

# output layer'da recurrent softmax kullanirsak:
# W_in_to_hid=lasagne.init. GlorotUniform(gain=1.0) # aka Xavier initialization.
# W_hid_to_hid=Identity(),
# b=lasagne.init.Constant(0.)
# hid_init=lasagne.init.Constant(0.)

fnet = Net(peeplstm; out=hidden, winit=winit)
bnet = Net(peeplstm; out=hidden, winit=winit)
pnet = Net(add2; ninputs=2, out=nclass, f=soft, winit=Xavier())
model = Tagger(fnet, bnet, pnet)
setopt!(model; lr=lr)
losscnt = (fast ? nothing : zeros(2))
maxnorm = (fast ? nothing : zeros(2))
history = Any[]

for epoch=1:epochs
    @date train(model, trn, softloss; gclip=gclip, losscnt=losscnt, maxnorm=maxnorm, lossreport=lossreport)
    gcheck > 0 && (@date gradcheck(model, trn, softloss; gcheck=gcheck))
    @date devprp = exp(test(model, dev, softloss))
    @date deverr = test(model, dev, zeroone)
    @show (epoch, devprp, deverr)
    push!(history, deverr)
    if length(history) > 5 && history[end] > history[end-5]
        @show lr /= 2
        setopt!(model; lr=lr)
    end
    flush(STDOUT)
end