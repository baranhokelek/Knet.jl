"""
S2S(net::Function) implements the sequence to sequence model from:
Sutskever, I., Vinyals, O., & Le, Q. V. (2014). Sequence to sequence
learning with neural networks. Advances in neural information
processing systems, 3104-3112.  The @knet function `net` is duplicated
to create an encoder and a decoder.  See `S2SData` for data format.
"""
immutable S2S <: Model; encoder; decoder; params;
    function S2S(kfun::Function; o...)
        enc = Net(encoder; o..., f=kfun)
        dec = Net(decoder; o..., f=kfun)
        new(enc, dec, vcat(params(enc), params(dec)))
    end
end

params(m::S2S)=m.params
reset!(m::S2S; o...)=(reset!(m.encoder; o...);reset!(m.decoder; o...))

@knet function encoder(word; f=nothing, hidden=0, o...)
    wvec = wdot(word; o..., out=hidden)
    hvec = f(wvec; o..., out=hidden)
end

@knet function decoder(word; f=nothing, hidden=0, vocab=0, o...)
    hvec = encoder(word; o..., f=f, hidden=hidden)
    tvec = wdot(hvec; out=vocab)
    pvec = soft(tvec)
end

train(m::S2S, data, loss; o...)=s2s_loop(m, data, loss; trn=true, ystack=Any[], o...)

test(m::S2S, data, loss; o...)=(l=zeros(2); s2s_loop(m, data, loss; losscnt=l, o...); l[1]/l[2])

function s2s_loop(m::S2S, data, loss; gcheck=false, o...)
    decoding = false
    reset!(m; o...)
    for (x,ygold,mask) in data
        if decoding && ygold == nothing # the next sentence started
            gcheck && break
            s2s_eos(m, data, loss; gcheck=gcheck, o...)
            reset!(m; o...)
            decoding = false
        end
        if !decoding && ygold != nothing # source ended, target sequence started
            s2s_copyforw!(m)
            decoding = true
        end
        if decoding && ygold != nothing # keep decoding target
            s2s_decode(m, x, ygold, mask, loss; o...)
        end
        if !decoding && ygold == nothing # keep encoding source
            s2s_encode(m, x; o...)
        end
    end
    s2s_eos(m, data, loss; gcheck=gcheck, o...)
end

function s2s_encode(m::S2S, x; trn=false, o...)
    forw(m.encoder, x; trn=trn, seq=true, o...)
end    

function s2s_decode(m::S2S, x, ygold, mask, loss; trn=false, ystack=nothing, losscnt=nothing, o...)
    ypred = forw(m.decoder, x; trn=trn, seq=true, o...)
    ystack != nothing  && push!(ystack, (copy(ygold),copy(mask))) # TODO: get rid of alloc
    (yrows, ycols) = size2(ygold)
    nwords = (mask == nothing ? ycols : sum(mask))
    # loss divides total loss by minibatch size ycols.  at the end the total loss will be equal to
    # losscnt[1]*ycols.  losscnt[1]/losscnt[2] will equal totalloss/totalwords.
    losscnt != nothing && (losscnt[1] += loss(ypred,ygold;mask=mask); losscnt[2] += nwords/ycols)
end

function s2s_eos(m::S2S, data, loss; trn=false, gcheck=false, ystack=nothing, maxnorm=nothing, gclip=0, o...)
    if trn
        s2s_bptt(m, ystack, loss; o...)
        g = (gclip > 0 || maxnorm!=nothing ? gnorm(m) : 0)
        if !gcheck
            gclip=(g > gclip > 0 ? gclip/g : 0)
            update!(m; gclip=gclip, o...)
        end
    end
    if maxnorm != nothing
        w=wnorm(m)
        w > maxnorm[1] && (maxnorm[1]=w)
        g > maxnorm[2] && (maxnorm[2]=g)
    end
end

function s2s_bptt(m::S2S, ystack, loss; o...)
    while !isempty(ystack)
        (ygold,mask) = pop!(ystack)
        back(m.decoder, ygold, loss; seq=true, mask=mask, o...)
    end
    @assert m.decoder.sp == 0
    s2s_copyback!(m)
    while m.encoder.sp > 0
        back(m.encoder; seq=true, o...)
    end
end

function s2s_copyforw!(m::S2S)
    for n=1:nops(m.encoder)
        if forwref(m.encoder, n)
            # m.decoder.out0[n] == nothing && (m.decoder.out0[n] = similar(m.encoder.out[n]))
            # m.decoder.out[n] = copy!(m.decoder.out0[n], m.encoder.out[n])
            m.decoder.out[n] = m.decoder.out0[n] = m.encoder.out[n]
        end
    end
end

function s2s_copyback!(m::S2S)
    for n=1:nops(m.encoder)
        if forwref(m.encoder, n)
            # m.encoder.dif0[n] == nothing && (m.encoder.dif0[n] = similar(m.decoder.dif[n]))
            # m.encoder.dif[n] = copy!(m.encoder.dif0[n], m.decoder.dif[n])
            m.encoder.dif[n] = m.encoder.dif0[n] = m.decoder.dif[n]
        end
    end
end


"""
S2SData(sourcefile, targetfile; batch=20, ftype=Float32, dense=false, dict1=Dict(), dict2=Dict())
creates a data generator that can be used with an S2S model.  The
inputs sourcefile and targetfile should contain the desired source and
target sequences with one sequence per line consisting of space
separated tokens.
    
The following transformations are performed by an S2SData generator:

* sequences are minibatched according to the batch argument.
* sequences in a minibatch padded to all be the same length.
* sequences are sorted by length to minimize padding.
* the source sequences are generated in reverse order.
* source tokens are presented as (x,nothing) pairs
* target tokens are presented as (x[t-1],x[t]) pairs

Example:
```
sourcefile:
The dog ran
The next sentence

targetfile:
El perror corrio
La frase siguiente
```
order of items generated by S2SData(sourcefile, targetfile):
```
(<s>,nothing)
(ran,nothing)
(dog,nothing)
(The,nothing)
(<s>,El)
(El,perror)
(perror,corrio)
(corrio,<s>)
(<s>,nothing)
(sentence,nothing)
(next,nothing)
(The,nothing)
(<s>,La)
(La,frase)
(frase,siguiente)
(siguiente,<s>)
```
(except each word will be represented by a one-hot vector, and with
minibatch > 1, words from multiple sentences will be concatented in 
a matrix.)

Note that the end-of-sentence markers <s> are automatically inserted
by the S2SData generator and are not present in the sourcefile or the
targetfile.  The S2S model switches between encoding and decoding
using y=nothing as an indicator.    
"""
type S2SData; data1; data2; dict1; dict2; batch; ftype; dense; x; y; mask; stop; end

# TODO: get rid of the stop field if no longer used.

function S2SData(file1::AbstractString, file2::AbstractString; batch=128, block=10, ftype=Float32, dense=false,
                 dict1=Dict{Any,Int32}(), dict2=Dict{Any,Int32}(), stop=typemax(Int))
    data1 = loadseq(file1, dict1)
    data2 = loadseq(file2, dict2)
    @assert length(data1) == length(data2)
    sorted = sortblocks(data1; batch=batch, block=block)
    data1 = data1[sorted]
    data2 = data2[sorted]
    ns = length(data1)
    batch > ns && (batch = ns; warn("Changing batchsize to $batch"))
    skip = ns % batch
    if skip > 0
        keep = ns - skip
        nw1 = sum(map(length, sub(data1,1:keep)))
        nw2 = sum(map(length, sub(data2,1:keep)))
        warn("Skipping $ns % $batch = $skip lines at the end leaving ns=$keep nw1=$nw1 nw2=$nw2.")
    end
    S2SData(data1, data2, dict1, dict2, batch, ftype, dense, nothing, nothing, nothing, stop)
end

const eosstr = "<s>"
const eos = 1

function sortblocks(data; batch=128, block=10)
    perm = Int[]
    n = length(data)
    bb = batch*block
    for i=1:bb:n
        j=i+bb-1
        j > n && (j=n)
        pi = sortperm(sub(data,i:j), by=length)
        append!(perm, (pi + (i-1)))
    end
    return perm
end

function loadseq(fname::AbstractString, dict=Dict{Any,Int32}())
    data = Vector{Int32}[]
    isempty(dict) && (dict[eosstr]=eos)
    open(fname) do f
        for l in eachline(f)
            sent = Int32[]
            for w in split(l)
                push!(sent, get!(dict, w, 1+length(dict)))
            end
            push!(data, sent)
        end
    end
    info("Read $fname[ns=$(length(data)),nw=$(mapreduce(length,+,data)),nd=$(length(dict))]")
    return data
end

import Base: start, done, next

# the state consists of (nbatch, nword, decode), where nbatch is the
# number of batches completed, and nword is the number of words
# completed in the current batch, and decode is a boolean indicating
# whether we are in the decoding phase.
function next(d::S2SData, state)
    (nbatch, nword, decode) = state 
    s1 = d.batch * nbatch + 1
    s2 = d.batch * (nbatch + 1)
    if !decode                  # gen data1[s1:s2] in reverse for encoding
        sentences = sub(d.data1, s1:s2)
        maxlen = 1 + maximum(map(length, sentences))
        w = maxlen-nword
        for s=1:length(sentences)
            n=length(sentences[s])
            xword = (w <= n ? sentences[s][w] :
                     w == n+1 ? eos : 0)
            if xword != 0
                d.mask[s] = 1
                setrow!(d.x, xword, s)
            else
                d.mask[s] = 0
                setrow!(d.x, 0, s)
            end
        end
        nword += 1
        nword == maxlen && (nword = 0; decode = true)
        return ((d.x, nothing, d.mask), (nbatch, nword, decode))
    else                        # gen data2[s1:s2] for decoding
        sentences = sub(d.data2, s1:s2)
        maxlen = 1 + maximum(map(length, sentences))
        for s=1:length(sentences)
            n=length(sentences[s])
            xword = (nword == 0 ? eos : 1 <= nword <= n ? sentences[s][nword] : 0)
            yword = (nword < n ? sentences[s][nword+1] : nword == n ? eos : 0)
            if xword != 0
                @assert yword != 0
                d.mask[s] = 1
                setrow!(d.x, xword, s)
                setrow!(d.y, yword, s)
            else
                d.mask[s] = 0
                setrow!(d.x, 0, s)
                setrow!(d.y, 0, s)
            end
        end
        nword += 1
        nword == maxlen && (nbatch += 1; nword = 0; decode = false)
        return ((d.x, d.y, d.mask), (nbatch, nword, decode))
    end
end

# TODO: these assume one hot columns, make them more general.
setrow!(x::SparseMatrixCSC,i,j)=(i>0 ? (x.rowval[j] = i; x.nzval[j] = 1) : (x.rowval[j]=1; x.nzval[j]=0))
setrow!(x::Array,i,j)=(x[:,j]=0; i>0 && (x[i,j]=1))
zerocolumn(x::SparseMatrixCSC,j)=(x.nzval[j]==0)
zerocolumn(x::Array,j)=(findfirst(sub(x,:,j))==0)

# we stop if there is not enough data for another full batch.
function done(d::S2SData,state)
    (nbatch, nword, decode) = state
    return ((nbatch+1)*d.batch > min(length(d.data1), d.stop))
end

# allocate the batch arrays if necessary
function start(d::S2SData)
    maxdict = max(length(d.dict1), length(d.dict2))
    if d.x == nothing || size(d.x) != (maxdict, d.batch)
        if d.dense
            d.x = zeros(d.ftype, maxdict, d.batch)
            d.y = zeros(d.ftype, maxdict, d.batch)
        else
            d.x = speye(d.ftype, maxdict, d.batch)
            d.y = speye(d.ftype, maxdict, d.batch)
        end
        d.mask = zeros(Cuchar, d.batch) # make this float for gpu
    end
    return (0, 0, false)
end


# FAQ:
#
# Q: How do we handle the transition?  Is eos fed to the encoder or the decoder?
#   It looks like the decoder from the picture.  We handle switch using the state variable.
# Q: Do we feed one best, distribution, or gold for word[t-1] to the decoder?
#   Gold during training, one-best output during testing?  (could also try the actual softmax output)
# Q: How do we handle the sequence ending?  How is the training signal passed back?
#   gold outputs, bptt first through decoder then encoder, triggered by output eos (or data=nothing when state=decode)
# Q: input reversal?
#   handled by the data generator
# Q: batching and padding of inputs of different length?
#   handled by the data generator
# Q: data format? <eos> ran dog The <eos> el perror corrio <eos> sentence next The <eos> its spanish version <eos> ...
#   so data does not need to have x/y pairs, just a y sequence for training (and testing?).
#   we could use nothings to signal eos, but we do need an actual encoding for <eos>
#   so don't replace <eos>, keep it, just insert nothings at the end of each sentence.
#   except in the very beginning, a state variable keeps track of encoding vs decoding
# Q: how about the data generator gives us x/y pairs:
#   during encoding we get x/nothing as desired input/output.
#   during decoding we get x[t-1]/x[t] as desired input/output.
#   this is more in line with what we did with rnnlm,
#   also in line with models not caring about how data is formatted, only desired input/output.
#   in this design we can distinguish encoding/decoding by looking at output
# Q: test time: 
#   encode proceeds normally
#   when we reach nothing, we switch to decoding
#   when we reach nothing again, we perform bptt (need stack for gold output, similar to rnnlm)
#   the first token to decoder gets fed from the gold (presumably <eos>)
#   the subsequent input tokens come from decoder's own output
#   second nothing resets and switches to encoding, no bptt
# Q: beam search?
#   don't need this for training or test perplexity
#   don't need this for one best greedy output
#   it will make minibatching more difficult
#   this is a problem for predict (TODO)
# Q: gradient scaling?
#   this becomes a problem once we start doing minibatching and padding short sequences.  I started
#   dividing loss and its gradients with minibatch size so the choice of minibatch does not effect
#   the step sizes and require a different learning rate.  In s2s if we have a sequence minibatch of
#   size N, which consists of T token minibatches each of size N.  Some sequences in the minibatch
#   are shorter so some of the token minibatches contain padding.  Say a particular token minibatch
#   contains n<N real words, the rest is padding.  Do we normalize using n or N?  It turns out in
#   this case the correct answer is N because we do not want the word in this minibatch to have
#   higher weight compared to other words in the sequence!
# Q: do we zero out padded columns?
#   We should set padding columns to zero in the input.  Otherwise when
#   the next time step has a legitimate word in that column, the hidden
#   state column will not be zero.


### DEAD CODE:
    # if losscnt != nothing 
    #     l = loss(ypred, ygold)  # returns total loss / num columns ignoring padding
    #     ycols = size(ygold,2)
    #     nzcols = 0
    #     for j=1:ycols; zerocolumn(ygold,j) || (nzcols += 1); end
    #     losscnt[1] += l # this has been scaled by (1/ycols) by the loss function
    #     losscnt[2] += (nzcols/ycols)    # this should work as long as loss for padded columns is 0 as it should be
    # end
