function pD = compute_pD(model,X)

if isempty(X)
    pD= [];
else
    max= 0.98;
    mid= [0; 0];
    cov= diag([6000,6000].^2);
    
    M= size(X,2);
    P= X([1 3],:);
    e_sq= sum( (diag(1./diag(sqrt(cov)))*(P-repmat(mid,[1 M]))).^2 );
    
    pD= max*exp(-e_sq/2);
   %pD= 0.98*ones(1,size(X,2));
end

